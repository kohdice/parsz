const std = @import("std");
const parser = @import("parser.zig");
const spec_command = @import("spec/command.zig");
const errors_mod = @import("errors.zig");
const validator = @import("validator.zig");
const help_usage = @import("help/usage.zig");
const help_render = @import("help/render.zig");

pub const ParseError = errors_mod.ParseError;
pub const Diagnostic = errors_mod.Diagnostic;
pub const FlagRef = errors_mod.FlagRef;
pub const FieldConfig = parser.FieldConfig;

/// Parse command-line arguments and return a value of type T.
///
/// T is a user-defined struct whose field types determine behavior automatically:
///   - `bool`          → flag (set to true when present)
///   - `?T`            → optional (null when not specified)
///   - `T` (no default)→ required
///   - `T` (default)   → option with default value
///   - `[]const T`     → multi-value (append)
///   - `enum`          → enum value parsing
///   - `union(enum)`   → subcommand
///
/// Subcommand precedence: when a bare positional token matches a
/// subcommand variant name, it is consumed as a subcommand.  Use the
/// `--` end-of-options separator to pass a colliding value as a
/// positional argument instead.
///
/// config is an anonymous struct specifying per-field settings (short, long, positional, etc.).
/// argv should be the slice from std.process.argsAlloc()[1..].
///
/// Multi fields (`[]const T`) perform heap allocation; call `deinit` after use
/// or manually free the returned slices.
///
/// Pass a `*Diagnostic` to receive detailed context on parse errors, or `null`
/// to skip diagnostic reporting.
pub fn parse(
    comptime T: type,
    allocator: std.mem.Allocator,
    argv: []const [:0]const u8,
    comptime config: anytype,
    diagnostic: ?*Diagnostic,
) (ParseError || error{OutOfMemory})!T {
    @setEvalBranchQuota(10_000);
    const cmd_spec = comptime spec_command.buildSpec(T, config);
    return parser.parseCore(T, allocator, argv, config, diagnostic, cmd_spec.subcommand_field);
}

/// Free heap memory allocated for multi fields (`[]const T`).
pub fn deinit(
    comptime T: type,
    result: *T,
    allocator: std.mem.Allocator,
    comptime config: anytype,
) void {
    @setEvalBranchQuota(10_000);
    parser.deinitFields(T, result, allocator, config);
}

/// Write the complete help text for the CLI type T.
///
/// Generates formatted help output including about text, usage line,
/// arguments, options (with defaults), and subcommand listing.
/// The help text is derived from the type definition and config at compile time.
pub fn help(comptime T: type, comptime config: anytype, writer: anytype) !void {
    @setEvalBranchQuota(10_000);
    comptime {
        validator.validate(T, config);
        const cmd_spec = spec_command.buildSpec(T, config);
        if (cmd_spec.subcommand_field) |sfn| {
            validator.validateSubcommandConfig(T, config, sfn);
        }
    }
    try help_render.writeHelp(T, config, writer);
}

/// Write the usage line for the CLI type T.
///
/// Generates a single-line usage summary (e.g., "Usage: myapp [OPTIONS] <INPUT>").
pub fn usage(comptime T: type, comptime config: anytype, writer: anytype) !void {
    @setEvalBranchQuota(10_000);
    comptime {
        validator.validate(T, config);
        const cmd_spec = spec_command.buildSpec(T, config);
        if (cmd_spec.subcommand_field) |sfn| {
            validator.validateSubcommandConfig(T, config, sfn);
        }
    }
    try help_usage.writeUsage(T, config, writer);
}

test "parse: basic flag" {
    const Cli = struct { verbose: bool = false };
    const result = try parse(Cli, std.testing.allocator, &.{"--verbose"}, .{}, null);
    try std.testing.expect(result.verbose);
}

test "parse: string option with default" {
    const Cli = struct { output: []const u8 = "out.txt" };
    const result = try parse(Cli, std.testing.allocator, &.{ "--output", "file.txt" }, .{}, null);
    try std.testing.expectEqualStrings("file.txt", result.output);
}

test "parse: required positional" {
    const Cli = struct { input: []const u8 };
    const result = try parse(Cli, std.testing.allocator, &.{"hello.txt"}, .{
        .input = .{ .positional = true },
    }, null);
    try std.testing.expectEqualStrings("hello.txt", result.input);
}

test "parse: subcommand" {
    const Clone = struct {
        remote: []const u8,
    };
    const Push = struct {
        force: bool = false,
    };
    const Command = union(enum) {
        clone: Clone,
        push: Push,
    };
    const Cli = struct {
        verbose: bool = false,
        command: ?Command = null,
    };

    const result = try parse(Cli, std.testing.allocator, &.{ "--verbose", "clone", "origin" }, .{
        .command = .{
            .clone = .{
                .remote = .{ .positional = true },
            },
        },
    }, null);

    try std.testing.expect(result.verbose);
    try std.testing.expect(result.command != null);
    switch (result.command.?) {
        .clone => |c| try std.testing.expectEqualStrings("origin", c.remote),
        .push => unreachable,
    }
}

test "parse: subcommand with flags" {
    const Push = struct {
        force: bool = false,
        remote: []const u8 = "origin",
    };
    const Command = union(enum) {
        push: Push,
    };
    const Cli = struct {
        command: ?Command = null,
    };

    const result = try parse(Cli, std.testing.allocator, &.{ "push", "--force", "--remote", "upstream" }, .{
        .command = .{
            .push = .{
                .force = .{ .short = 'f' },
            },
        },
    }, null);

    try std.testing.expect(result.command != null);
    switch (result.command.?) {
        .push => |p| {
            try std.testing.expect(p.force);
            try std.testing.expectEqualStrings("upstream", p.remote);
        },
    }
}

test "parse: optional subcommand null" {
    const Command = union(enum) {
        run: struct {},
    };
    const Cli = struct {
        verbose: bool = false,
        command: ?Command = null,
    };

    const result = try parse(Cli, std.testing.allocator, &.{"--verbose"}, .{}, null);
    try std.testing.expect(result.verbose);
    try std.testing.expect(result.command == null);
}

test "parse: optional field without explicit default" {
    const Cli = struct { config_path: ?[]const u8 };
    const result = try parse(Cli, std.testing.allocator, &.{}, .{}, null);
    try std.testing.expect(result.config_path == null);
}

test "parse: optional field without explicit default with value" {
    const Cli = struct { config_path: ?[]const u8 };
    const result = try parse(Cli, std.testing.allocator, &.{ "--config-path", "cfg.toml" }, .{}, null);
    try std.testing.expectEqualStrings("cfg.toml", result.config_path.?);
}

test "parse: optional subcommand without explicit default" {
    const Command = union(enum) {
        run: struct {},
    };
    const Cli = struct {
        verbose: bool = false,
        command: ?Command,
    };

    const result = try parse(Cli, std.testing.allocator, &.{"--verbose"}, .{}, null);
    try std.testing.expect(result.verbose);
    try std.testing.expect(result.command == null);
}

test "parse: deinit with multi field" {
    const Cli = struct { ports: []const u16 = &.{} };
    var result = try parse(Cli, std.testing.allocator, &.{ "--ports", "80", "--ports", "443" }, .{}, null);
    defer deinit(Cli, &result, std.testing.allocator, .{});
    try std.testing.expectEqual(@as(usize, 2), result.ports.len);
}

test "parse: combined short long positional" {
    const Cli = struct {
        verbose: bool = false,
        output: []const u8 = "out.txt",
        count: u32 = 1,
        input: []const u8,
    };

    const result = try parse(Cli, std.testing.allocator, &.{ "-v", "--output=result.txt", "--count", "5", "data.csv" }, .{
        .verbose = .{ .short = 'v' },
        .output = .{ .short = 'o' },
        .input = .{ .positional = true },
    }, null);

    try std.testing.expect(result.verbose);
    try std.testing.expectEqualStrings("result.txt", result.output);
    try std.testing.expectEqual(@as(u32, 5), result.count);
    try std.testing.expectEqualStrings("data.csv", result.input);
}

test "parse: enum option" {
    const Mode = enum { fast, slow, balanced };
    const Cli = struct {
        mode: Mode = .balanced,
    };

    const result = try parse(Cli, std.testing.allocator, &.{ "--mode", "fast" }, .{}, null);
    try std.testing.expectEqual(Mode.fast, result.mode);
}

test "parse: no leak when multi field set but required subcommand missing" {
    const Command = union(enum) {
        run: struct {},
    };
    const Cli = struct {
        ports: []const u16 = &.{},
        command: Command,
    };

    const result = parse(Cli, std.testing.allocator, &.{ "--ports", "80" }, .{}, null);
    try std.testing.expectError(error.MissingSubcommand, result);
}

test "parse: deinit optional multi field" {
    const Cli = struct { ports: ?[]const u16 = null };
    var result = try parse(Cli, std.testing.allocator, &.{ "--ports", "80", "--ports", "443" }, .{}, null);
    defer deinit(Cli, &result, std.testing.allocator, .{});
    try std.testing.expect(result.ports != null);
    try std.testing.expectEqual(@as(usize, 2), result.ports.?.len);
}

test "parse: end of options prevents subcommand matching" {
    const Run = struct { file: []const u8 };
    const Command = union(enum) { run: Run };
    const Cli = struct {
        input: []const u8,
        command: ?Command = null,
    };
    const config = .{
        .input = .{ .positional = true },
        .command = .{ .run = .{ .file = .{ .positional = true } } },
    };

    // "-- run" should treat "run" as positional input, not as subcommand
    const result = try parse(Cli, std.testing.allocator, &.{ "--", "run" }, config, null);
    try std.testing.expectEqualStrings("run", result.input);
    try std.testing.expect(result.command == null);
}

test "parse: end of options with flags and subcommand name" {
    const Push = struct { force: bool = false };
    const Command = union(enum) { push: Push };
    const Cli = struct {
        verbose: bool = false,
        target: []const u8,
        command: ?Command = null,
    };
    const config = .{
        .verbose = .{ .short = 'v' },
        .target = .{ .positional = true },
        .command = .{},
    };

    // "--verbose -- push" should treat "push" as positional target
    const result = try parse(Cli, std.testing.allocator, &.{ "--verbose", "--", "push" }, config, null);
    try std.testing.expect(result.verbose);
    try std.testing.expectEqualStrings("push", result.target);
    try std.testing.expect(result.command == null);
}

test "parse: unresolved subcommand reports UnknownSubcommand" {
    const Command = union(enum) { run: struct {} };
    const Cli = struct {
        input: []const u8,
        command: ?Command = null,
    };
    const config = .{
        .input = .{ .positional = true },
        .command = .{},
    };

    // "file.txt extra" — first positional fills input, second is unknown subcommand
    const result = parse(Cli, std.testing.allocator, &.{ "file.txt", "extra" }, config, null);
    try std.testing.expectError(error.UnknownSubcommand, result);
}

test "parse: unknown subcommand" {
    const Command = union(enum) { run: struct {} };
    const Cli = struct {
        command: Command,
    };
    const config = .{ .command = .{} };

    // "bogus" matches no subcommand and no positional field
    const result = parse(Cli, std.testing.allocator, &.{"bogus"}, config, null);
    try std.testing.expectError(error.UnknownSubcommand, result);
}

test "parse: end of options with too many positionals" {
    const Command = union(enum) { run: struct {} };
    const Cli = struct {
        input: []const u8,
        command: ?Command = null,
    };
    const config = .{
        .input = .{ .positional = true },
        .command = .{},
    };

    // "-- file.txt extra" — after --, positional overflow should be TooManyPositionals
    const result = parse(Cli, std.testing.allocator, &.{ "--", "file.txt", "extra" }, config, null);
    try std.testing.expectError(error.TooManyPositionals, result);
}

test "parse: no subcommand heap leak on optional subcmd with missing required field" {
    const Install = struct {
        packages: []const []const u8 = &.{},
    };
    const Command = union(enum) {
        install: Install,
    };
    const Cli = struct {
        host: []const u8,
        command: ?Command = null,
    };
    const config = .{
        .host = .{ .positional = true },
        .command = .{
            .install = .{
                .packages = .{ .positional = true },
            },
        },
    };

    // Subcommand "install" is parsed (with heap-allocated packages slice),
    // but top-level required field "host" is missing → MissingRequired.
    // The errdefer must free the subcommand's multi-field allocation.
    const result = parse(Cli, std.testing.allocator, &.{ "install", "pkg-a", "pkg-b" }, config, null);
    try std.testing.expectError(error.MissingRequired, result);
}

test "parse: no subcommand heap leak on non-optional subcmd with missing required field" {
    const Install = struct {
        packages: []const []const u8 = &.{},
    };
    const Command = union(enum) {
        install: Install,
    };
    const Cli = struct {
        host: []const u8,
        command: Command,
    };
    const config = .{
        .host = .{ .positional = true },
        .command = .{
            .install = .{
                .packages = .{ .positional = true },
            },
        },
    };

    // Same scenario but with non-optional subcommand field.
    const result = parse(Cli, std.testing.allocator, &.{ "install", "pkg-a" }, config, null);
    try std.testing.expectError(error.MissingRequired, result);
}

test "parse: deinit subcommand double call safety" {
    const Install = struct {
        packages: []const []const u8 = &.{},
    };
    const Command = union(enum) {
        install: Install,
    };
    const Cli = struct {
        command: ?Command = null,
    };
    const config = .{
        .command = .{
            .install = .{
                .packages = .{ .positional = true },
            },
        },
    };

    var result = try parse(Cli, std.testing.allocator, &.{ "install", "pkg-a", "pkg-b" }, config, null);
    // First deinit frees the allocation and resets via @unionInit writeback.
    deinit(Cli, &result, std.testing.allocator, config);
    // Second deinit must be safe (no double free) because payload was reset.
    deinit(Cli, &result, std.testing.allocator, config);
}

test "nested subcommand basic" {
    const InnerCommand = union(enum) {
        add: struct { name: []const u8 },
        remove: struct { name: []const u8 },
    };
    const OuterCommand = union(enum) {
        remote: struct { command: InnerCommand },
    };
    const Cli = struct {
        verbose: bool = false,
        command: OuterCommand,
    };
    const config = .{
        .command = .{
            .remote = .{
                .command = .{
                    .add = .{ .name = .{ .positional = true } },
                    .remove = .{ .name = .{ .positional = true } },
                },
            },
        },
    };

    const result = try parse(Cli, std.testing.allocator, &.{ "--verbose", "remote", "add", "origin" }, config, null);
    try std.testing.expect(result.verbose);
    switch (result.command) {
        .remote => |r| switch (r.command) {
            .add => |a| try std.testing.expectEqualStrings("origin", a.name),
            .remove => unreachable,
        },
    }
}

test "nested subcommand with positional" {
    const InnerCommand = union(enum) {
        add: struct { name: []const u8, url: []const u8 },
    };
    const OuterCommand = union(enum) {
        remote: struct { command: InnerCommand },
    };
    const Cli = struct {
        command: OuterCommand,
    };
    const config = .{
        .command = .{
            .remote = .{
                .command = .{
                    .add = .{
                        .name = .{ .positional = true },
                        .url = .{ .positional = true },
                    },
                },
            },
        },
    };

    const result = try parse(Cli, std.testing.allocator, &.{ "remote", "add", "origin", "https://example.com" }, config, null);
    switch (result.command) {
        .remote => |r| switch (r.command) {
            .add => |a| {
                try std.testing.expectEqualStrings("origin", a.name);
                try std.testing.expectEqualStrings("https://example.com", a.url);
            },
        },
    }
}

test "nested subcommand deinit with multi" {
    const InnerCommand = union(enum) {
        install: struct { packages: []const []const u8 = &.{} },
    };
    const OuterCommand = union(enum) {
        pkg: struct { command: InnerCommand },
    };
    const Cli = struct {
        command: OuterCommand,
    };
    const config = .{
        .command = .{
            .pkg = .{
                .command = .{
                    .install = .{
                        .packages = .{ .positional = true },
                    },
                },
            },
        },
    };

    var result = try parse(Cli, std.testing.allocator, &.{ "pkg", "install", "foo", "bar" }, config, null);
    defer deinit(Cli, &result, std.testing.allocator, config);
    switch (result.command) {
        .pkg => |p| switch (p.command) {
            .install => |i| try std.testing.expectEqual(@as(usize, 2), i.packages.len),
        },
    }
}

test "nested optional subcommand null" {
    const InnerCommand = union(enum) {
        add: struct { name: []const u8 },
    };
    const OuterCommand = union(enum) {
        remote: struct { command: ?InnerCommand = null },
    };
    const Cli = struct {
        command: OuterCommand,
    };
    const config = .{
        .command = .{
            .remote = .{
                .command = .{
                    .add = .{ .name = .{ .positional = true } },
                },
            },
        },
    };

    const result = try parse(Cli, std.testing.allocator, &.{"remote"}, config, null);
    switch (result.command) {
        .remote => |r| try std.testing.expect(r.command == null),
    }
}

test "nested missing required subcommand" {
    const InnerCommand = union(enum) {
        add: struct {},
        remove: struct {},
    };
    const OuterCommand = union(enum) {
        remote: struct { command: InnerCommand },
    };
    const Cli = struct {
        command: OuterCommand,
    };
    const config = .{
        .command = .{
            .remote = .{
                .command = .{},
            },
        },
    };

    const result = parse(Cli, std.testing.allocator, &.{"remote"}, config, null);
    try std.testing.expectError(error.MissingSubcommand, result);
}

test "nested unknown subcommand error" {
    const InnerCommand = union(enum) {
        add: struct {},
    };
    const OuterCommand = union(enum) {
        remote: struct { command: InnerCommand },
    };
    const Cli = struct {
        command: OuterCommand,
    };
    const config = .{
        .command = .{
            .remote = .{
                .command = .{},
            },
        },
    };

    const result = parse(Cli, std.testing.allocator, &.{ "remote", "bogus" }, config, null);
    try std.testing.expectError(error.UnknownSubcommand, result);
}

test "nested unknown flag error" {
    const InnerCommand = union(enum) {
        add: struct { name: []const u8 },
    };
    const OuterCommand = union(enum) {
        remote: struct { command: InnerCommand },
    };
    const Cli = struct {
        command: OuterCommand,
    };
    const config = .{
        .command = .{
            .remote = .{
                .command = .{
                    .add = .{ .name = .{ .positional = true } },
                },
            },
        },
    };

    const result = parse(Cli, std.testing.allocator, &.{ "remote", "add", "--nonexistent" }, config, null);
    try std.testing.expectError(error.UnknownFlag, result);
}

test "nested subcommand no leak on error" {
    const InnerCommand = union(enum) {
        install: struct { packages: []const []const u8 = &.{} },
    };
    const OuterCommand = union(enum) {
        pkg: struct {
            required_field: []const u8,
            command: InnerCommand,
        },
    };
    const Cli = struct {
        command: OuterCommand,
    };
    const config = .{
        .command = .{
            .pkg = .{
                .required_field = .{ .positional = true },
                .command = .{
                    .install = .{
                        .packages = .{ .positional = true },
                    },
                },
            },
        },
    };

    // "pkg install foo bar" — subcommand "install" is parsed with heap-allocated
    // packages, but the outer struct's required_field is missing → MissingRequired.
    // The errdefer chain must free the nested multi-field allocation.
    const result = parse(Cli, std.testing.allocator, &.{ "pkg", "install", "foo", "bar" }, config, null);
    try std.testing.expectError(error.MissingRequired, result);
}

test "parse: bool flag rejects inline value" {
    const Cli = struct { verbose: bool = false };
    const result = parse(Cli, std.testing.allocator, &.{"--verbose=false"}, .{}, null);
    try std.testing.expectError(error.InvalidValue, result);
}

test "parse: positional plus invalid subcommand name" {
    const Command = union(enum) { run: struct {} };
    const Cli = struct {
        input: []const u8,
        command: ?Command = null,
    };
    const config = .{
        .input = .{ .positional = true },
        .command = .{},
    };

    // "file.txt bogus" — first positional fills input, "bogus" is unknown subcommand
    const result = parse(Cli, std.testing.allocator, &.{ "file.txt", "bogus" }, config, null);
    try std.testing.expectError(error.UnknownSubcommand, result);
}

test "parse: subcommand parsed then extra positional" {
    const Run = struct { file: []const u8 };
    const Command = union(enum) { run: Run };
    const Cli = struct {
        command: Command,
    };
    const config = .{
        .command = .{
            .run = .{ .file = .{ .positional = true } },
        },
    };

    // "run file.txt extra" — subcommand parsed, extra positional in sub-parser → TooManyPositionals
    const result = parse(Cli, std.testing.allocator, &.{ "run", "file.txt", "extra" }, config, null);
    try std.testing.expectError(error.TooManyPositionals, result);
}

test "parse: deinit default subcommand with non-empty multi field" {
    const Install = struct {
        packages: []const []const u8 = &.{"default-pkg"},
    };
    const Command = union(enum) {
        install: Install,
    };
    const Cli = struct {
        verbose: bool = false,
        command: ?Command = .{ .install = .{} },
    };
    const config = .{
        .command = .{
            .install = .{
                .packages = .{ .positional = true },
            },
        },
    };

    // No subcommand in argv → default value with static slice is kept.
    // deinit must not crash on the non-heap "default-pkg" slice.
    var result = try parse(Cli, std.testing.allocator, &.{}, config, null);
    defer deinit(Cli, &result, std.testing.allocator, config);

    // Default value should be preserved.
    try std.testing.expect(result.command != null);
    switch (result.command.?) {
        .install => |inst| {
            try std.testing.expectEqual(@as(usize, 1), inst.packages.len);
            try std.testing.expectEqualStrings("default-pkg", inst.packages[0]);
        },
    }
}

test "parse: deinit nested default subcommand with non-empty multi field" {
    const Inner = struct {
        tags: []const []const u8 = &.{ "alpha", "beta" },
    };
    const InnerCommand = union(enum) {
        deploy: Inner,
    };
    const Outer = struct {
        command: ?InnerCommand = .{ .deploy = .{} },
    };
    const OuterCommand = union(enum) {
        service: Outer,
    };
    const Cli = struct {
        command: ?OuterCommand = .{ .service = .{} },
    };
    const config = .{
        .command = .{
            .service = .{
                .command = .{
                    .deploy = .{
                        .tags = .{ .positional = true },
                    },
                },
            },
        },
    };

    // No subcommand parsed → nested defaults with static slices must be
    // heap-normalized so deinit does not perform an invalid free.
    var result = try parse(Cli, std.testing.allocator, &.{}, config, null);
    defer deinit(Cli, &result, std.testing.allocator, config);

    try std.testing.expect(result.command != null);
    switch (result.command.?) {
        .service => |svc| {
            try std.testing.expect(svc.command != null);
            switch (svc.command.?) {
                .deploy => |d| {
                    try std.testing.expectEqual(@as(usize, 2), d.tags.len);
                    try std.testing.expectEqualStrings("alpha", d.tags[0]);
                    try std.testing.expectEqualStrings("beta", d.tags[1]);
                },
            }
        },
    }
}

test "parse: subcommand name takes precedence over positional" {
    const Command = union(enum) {
        run: struct {},
    };
    const Cli = struct {
        input: []const u8,
        command: ?Command = null,
    };
    const config = .{
        .input = .{ .positional = true },
        .command = .{},
    };

    // "run" matches the subcommand variant name, so it is consumed as a
    // subcommand rather than filling the positional "input" field.
    const result = parse(Cli, std.testing.allocator, &.{"run"}, config, null);
    try std.testing.expectError(error.MissingRequired, result);
}

test "parse: subcommand name takes precedence, dash-dash escapes to positional" {
    const Command = union(enum) {
        run: struct {},
    };
    const Cli = struct {
        input: []const u8,
        command: ?Command = null,
    };
    const config = .{
        .input = .{ .positional = true },
        .command = .{},
    };

    // "--" ends option/subcommand matching, so "run" is treated as a
    // positional value.
    const result = try parse(Cli, std.testing.allocator, &.{ "--", "run" }, config, null);
    try std.testing.expectEqualStrings("run", result.input);
    try std.testing.expect(result.command == null);
}

test "parse: subcommand name takes precedence, positional filled before subcommand" {
    const Command = union(enum) {
        run: struct {},
    };
    const Cli = struct {
        input: []const u8,
        command: ?Command = null,
    };
    const config = .{
        .input = .{ .positional = true },
        .command = .{},
    };

    // "file.txt" fills the positional, then "run" matches the subcommand.
    const result = try parse(Cli, std.testing.allocator, &.{ "file.txt", "run" }, config, null);
    try std.testing.expectEqualStrings("file.txt", result.input);
    try std.testing.expect(result.command != null);
}

test "parse: subcommand name takes precedence, kebab-case collision" {
    const Command = union(enum) {
        dry_run: struct {},
    };
    const Cli = struct {
        input: []const u8,
        command: ?Command = null,
    };
    const config = .{
        .input = .{ .positional = true },
        .command = .{},
    };

    // "dry-run" matches the kebab-case variant name "dry_run" → subcommand.
    const result = parse(Cli, std.testing.allocator, &.{"dry-run"}, config, null);
    try std.testing.expectError(error.MissingRequired, result);
}

test "parse: bool flag default true with subcommand succeeds" {
    const Command = union(enum) {
        run: struct {},
    };
    const Cli = struct {
        flag: bool = true,
        command: ?Command = null,
    };
    const config = .{
        .command = .{},
    };

    const result = try parse(Cli, std.testing.allocator, &.{ "--flag", "run" }, config, null);
    try std.testing.expect(result.flag == true);
    try std.testing.expect(result.command != null);
}

test "parse: diagnostic on InvalidValue" {
    const Mode = enum { fast, slow };
    const Cli = struct { mode: Mode = .fast };
    var diag: Diagnostic = .{};
    const result = parse(Cli, std.testing.allocator, &.{ "--mode", "invalid" }, .{}, &diag);
    try std.testing.expectError(error.InvalidValue, result);
    try std.testing.expectEqualStrings("mode", diag.arg_name);
    try std.testing.expectEqualStrings("mode", diag.flag.long);
    try std.testing.expectEqualStrings("invalid", diag.provided_value);
    try std.testing.expectEqualStrings("one of: fast, slow", diag.expected);
}

test "parse: diagnostic on UnknownFlag" {
    const Cli = struct { verbose: bool = false };
    var diag: Diagnostic = .{};
    const result = parse(Cli, std.testing.allocator, &.{"--unknown"}, .{}, &diag);
    try std.testing.expectError(error.UnknownFlag, result);
    try std.testing.expectEqualStrings("unknown", diag.flag.long);
}

test "parse: diagnostic on UnknownFlag short" {
    const Cli = struct { verbose: bool = false };
    var diag: Diagnostic = .{};
    const result = parse(Cli, std.testing.allocator, &.{"-x"}, .{}, &diag);
    try std.testing.expectError(error.UnknownFlag, result);
    try std.testing.expectEqual(@as(u8, 'x'), diag.flag.short);
}

test "parse: diagnostic on MissingValue" {
    const Cli = struct { output: []const u8 = "default" };
    var diag: Diagnostic = .{};
    const result = parse(Cli, std.testing.allocator, &.{"--output"}, .{}, &diag);
    try std.testing.expectError(error.MissingValue, result);
    try std.testing.expectEqualStrings("output", diag.arg_name);
    try std.testing.expectEqualStrings("output", diag.flag.long);
}

test "parse: diagnostic on MissingRequired" {
    const Cli = struct { host: []const u8 };
    var diag: Diagnostic = .{};
    const result = parse(Cli, std.testing.allocator, &.{}, .{
        .host = .{ .positional = true },
    }, &diag);
    try std.testing.expectError(error.MissingRequired, result);
    try std.testing.expectEqualStrings("host", diag.arg_name);
}

test "parse: diagnostic on ValueOutOfRange" {
    const Cli = struct { port: u16 = 0 };
    var diag: Diagnostic = .{};
    const result = parse(Cli, std.testing.allocator, &.{ "--port", "99999" }, .{}, &diag);
    try std.testing.expectError(error.ValueOutOfRange, result);
    try std.testing.expectEqualStrings("port", diag.arg_name);
    try std.testing.expectEqualStrings("port", diag.flag.long);
    try std.testing.expectEqualStrings("99999", diag.provided_value);
    try std.testing.expectEqualStrings("u16", diag.expected);
}

test "parse: diagnostic on DuplicateArg" {
    const Cli = struct { verbose: bool = false };
    var diag: Diagnostic = .{};
    const result = parse(Cli, std.testing.allocator, &.{ "--verbose", "--verbose" }, .{}, &diag);
    try std.testing.expectError(error.DuplicateArg, result);
    try std.testing.expectEqualStrings("verbose", diag.arg_name);
    try std.testing.expectEqualStrings("verbose", diag.flag.long);
}

test "parse: diagnostic on TooManyPositionals" {
    const Cli = struct { file: []const u8 };
    var diag: Diagnostic = .{};
    const result = parse(Cli, std.testing.allocator, &.{ "a.txt", "extra" }, .{
        .file = .{ .positional = true },
    }, &diag);
    try std.testing.expectError(error.TooManyPositionals, result);
    try std.testing.expectEqualStrings("extra", diag.provided_value);
    var buf: [256]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("invalid value 'extra'", rendered);
}

test "parse: diagnostic on UnknownSubcommand" {
    const Command = union(enum) { run: struct {} };
    const Cli = struct { command: Command };
    var diag: Diagnostic = .{};
    const result = parse(Cli, std.testing.allocator, &.{"bogus"}, .{ .command = .{} }, &diag);
    try std.testing.expectError(error.UnknownSubcommand, result);
    try std.testing.expectEqualStrings("bogus", diag.provided_value);
    var buf: [256]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("invalid value 'bogus'", rendered);
}

test "parse: diagnostic on MissingSubcommand" {
    const Command = union(enum) { run: struct {} };
    const Cli = struct { command: Command };
    var diag: Diagnostic = .{};
    const result = parse(Cli, std.testing.allocator, &.{}, .{ .command = .{} }, &diag);
    try std.testing.expectError(error.MissingSubcommand, result);
    try std.testing.expectEqualStrings("command", diag.arg_name);
}

test "parse: diagnostic null is safe" {
    const Cli = struct { verbose: bool = false };
    const result = parse(Cli, std.testing.allocator, &.{"--unknown"}, .{}, null);
    try std.testing.expectError(error.UnknownFlag, result);
}

test "parse: diagnostic format renders expected" {
    const Cli = struct { port: u16 = 0 };
    var diag: Diagnostic = .{};
    const result = parse(Cli, std.testing.allocator, &.{ "--port", "abc" }, .{}, &diag);
    try std.testing.expectError(error.InvalidValue, result);
    var buf: [256]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("argument '--port': invalid value 'abc' (expected u16)", rendered);
}

test "parse: --help returns HelpRequested" {
    const Cli = struct { verbose: bool = false };
    const result = parse(Cli, std.testing.allocator, &.{"--help"}, .{}, null);
    try std.testing.expectError(error.HelpRequested, result);
}

test "parse: -h returns HelpRequested" {
    const Cli = struct { verbose: bool = false };
    const result = parse(Cli, std.testing.allocator, &.{"-h"}, .{}, null);
    try std.testing.expectError(error.HelpRequested, result);
}

test "parse: --help=value returns HelpRequested" {
    const Cli = struct { verbose: bool = false };
    const result = parse(Cli, std.testing.allocator, &.{"--help=anything"}, .{}, null);
    try std.testing.expectError(error.HelpRequested, result);
}

test "parse: -- --help does not trigger help" {
    const Cli = struct { input: []const u8 };
    const result = try parse(Cli, std.testing.allocator, &.{ "--", "--help" }, .{
        .input = .{ .positional = true },
    }, null);
    try std.testing.expectEqualStrings("--help", result.input);
}

test "parse: -h overridden by user config does not trigger help" {
    const Cli = struct { host: []const u8 = "localhost" };
    const result = try parse(Cli, std.testing.allocator, &.{ "-h", "example.com" }, .{
        .host = .{ .short = 'h' },
    }, null);
    try std.testing.expectEqualStrings("example.com", result.host);
}

test "parse: --help overridden by user config does not trigger help" {
    const Cli = struct { help: bool = false };
    const result = try parse(Cli, std.testing.allocator, &.{"--help"}, .{}, null);
    try std.testing.expect(result.help);
}

test "parse: subcommand --help propagates HelpRequested" {
    const Command = union(enum) {
        run: struct { file: []const u8 = "default" },
    };
    const Cli = struct {
        verbose: bool = false,
        command: ?Command = null,
    };
    const result = parse(Cli, std.testing.allocator, &.{ "run", "--help" }, .{
        .command = .{},
    }, null);
    try std.testing.expectError(error.HelpRequested, result);
}

test "parse: _meta config is accepted without error" {
    const Cli = struct { verbose: bool = false };
    const result = try parse(Cli, std.testing.allocator, &.{"--verbose"}, .{
        ._meta = .{ .name = "myapp", .about = "A test app" },
    }, null);
    try std.testing.expect(result.verbose);
}

test "parse: help() produces output" {
    const Cli = struct {
        verbose: bool = false,
        input: []const u8,
    };
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try help(Cli, .{
        ._meta = .{ .name = "myapp", .about = "A test app" },
        .verbose = .{ .short = 'v', .help = "Enable verbose output" },
        .input = .{ .positional = true, .help = "Input file" },
    }, stream.writer());
    const output = stream.getWritten();
    try std.testing.expect(output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output, "A test app") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Usage: myapp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--verbose") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<INPUT>") != null);
}

test "parse: usage() produces output" {
    const Cli = struct { input: []const u8 };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try usage(Cli, .{
        ._meta = .{ .name = "myapp" },
        .input = .{ .positional = true },
    }, stream.writer());
    try std.testing.expectEqualStrings("Usage: myapp [OPTIONS] <INPUT>\n", stream.getWritten());
}

test {
    _ = @import("parser.zig");
    _ = @import("tokenizer.zig");
    _ = @import("errors.zig");
    _ = @import("help/usage.zig");
    _ = @import("help/render.zig");
}
