const std = @import("std");
const parser = @import("parser.zig");
const tokenizer_mod = @import("tokenizer.zig");
const errors_mod = @import("errors.zig");

const Tokenizer = tokenizer_mod.Tokenizer;
pub const ParseError = errors_mod.ParseError;
pub const FieldConfig = parser.FieldConfig;
const argKind = parser.argKind;
const getFieldConfig = parser.getFieldConfig;
const snakeToKebab = parser.snakeToKebab;
const unwrapOptional = parser.unwrapOptional;

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
/// config is an anonymous struct specifying per-field settings (short, long, positional, etc.).
/// argv should be the slice from std.process.argsAlloc()[1..].
///
/// Multi fields (`[]const T`) perform heap allocation; call `deinit` after use
/// or manually free the returned slices.
pub fn parse(
    comptime T: type,
    allocator: std.mem.Allocator,
    argv: []const [:0]const u8,
    comptime config: anytype,
) (ParseError || error{OutOfMemory})!T {
    @setEvalBranchQuota(10_000);

    const fields = @typeInfo(T).@"struct".fields;
    comptime var has_subcommand = false;
    comptime var subcmd_field_name: ?[]const u8 = null;
    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        if (comptime argKind(field.type, fc) == .subcommand) {
            has_subcommand = true;
            subcmd_field_name = field.name;
        }
    }

    if (comptime has_subcommand) {
        return parseWithSubcommand(T, allocator, argv, config, subcmd_field_name.?);
    } else {
        return parser.parseArgs(T, allocator, argv, config);
    }
}

/// Free heap memory allocated for multi fields (`[]const T`).
pub fn deinit(
    comptime T: type,
    result: *T,
    allocator: std.mem.Allocator,
    comptime config: anytype,
) void {
    @setEvalBranchQuota(10_000);

    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        const kind = comptime argKind(field.type, fc);
        if (kind == .multi) {
            if (comptime @typeInfo(field.type) == .optional) {
                if (@field(result, field.name)) |s| {
                    allocator.free(s);
                }
                @field(result, field.name) = null;
            } else {
                allocator.free(@field(result, field.name));
                @field(result, field.name) = &.{};
            }
        } else if (kind == .subcommand) {
            const SubType = comptime unwrapOptional(field.type);
            if (@typeInfo(field.type) == .optional) {
                if (@field(result, field.name)) |*sub| {
                    deinitSubcommand(SubType, sub, allocator, config, field.name);
                }
            } else {
                deinitSubcommand(SubType, &@field(result, field.name), allocator, config, field.name);
            }
        }
    }
}

fn parseWithSubcommand(
    comptime T: type,
    allocator: std.mem.Allocator,
    argv: []const [:0]const u8,
    comptime config: anytype,
    comptime subcmd_field_name: []const u8,
) (ParseError || error{OutOfMemory})!T {
    @setEvalBranchQuota(10_000);
    comptime parser.validateConfig(T, config);

    const fields = @typeInfo(T).@"struct".fields;
    const FieldEnum = std.meta.FieldEnum(T);

    var result: T = undefined;
    var field_set = std.EnumSet(FieldEnum).initEmpty();

    inline for (fields) |field| {
        if (field.default_value_ptr) |ptr| {
            const default = @as(*const field.type, @ptrCast(@alignCast(ptr))).*;
            @field(result, field.name) = default;
            field_set.insert(@field(FieldEnum, field.name));
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
            field_set.insert(@field(FieldEnum, field.name));
        }
    }

    const subcmd_field = comptime blk: {
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, subcmd_field_name)) break :blk f;
        }
        unreachable;
    };
    const SubUnion = comptime unwrapOptional(subcmd_field.type);
    const sub_fields = @typeInfo(SubUnion).@"union".fields;

    // Track whether subcommand was actually parsed (not just default-initialized).
    // Default values (e.g. `?Command = null`) are also in field_set, so we
    // cannot rely on field_set alone to decide whether to deinit on error.
    var subcmd_parsed = false;

    errdefer {
        if (subcmd_parsed) {
            if (@typeInfo(subcmd_field.type) == .optional) {
                if (@field(result, subcmd_field_name)) |*sub| {
                    deinitSubcommand(SubUnion, sub, allocator, config, subcmd_field_name);
                }
            } else {
                deinitSubcommand(SubUnion, &@field(result, subcmd_field_name), allocator, config, subcmd_field_name);
            }
        }
    }

    var tok = Tokenizer{ .args = argv };
    var positional_index: usize = 0;

    var lists = parser.initMultiLists(T, config);
    defer parser.deinitMultiLists(T, config, &lists, allocator);

    while (tok.next()) |token| {
        switch (token) {
            .long => |long| {
                if (!try parser.handleLong(T, config, &result, &field_set, &tok, &lists, long, allocator))
                    return error.UnknownFlag;
            },
            .short => |ch| {
                if (!try parser.handleShort(T, config, &result, &field_set, &tok, &lists, ch, allocator))
                    return error.UnknownFlag;
            },
            .positional => |val| {
                const slice: []const u8 = val;
                var found_sub = false;
                if (!tok.options_ended) {
                    inline for (sub_fields) |sf| {
                        if (std.mem.eql(u8, slice, comptime snakeToKebab(sf.name))) {
                            const remaining = tok.args[tok.index..];
                            const sub_config = comptime getSubVariantConfig(config, subcmd_field_name, sf.name);
                            const sub_result = try parser.parseArgs(sf.type, allocator, remaining, sub_config);
                            @field(result, subcmd_field_name) =
                                if (@typeInfo(subcmd_field.type) == .optional)
                                    @unionInit(SubUnion, sf.name, sub_result)
                                else
                                    @unionInit(SubUnion, sf.name, sub_result);
                            field_set.insert(@field(FieldEnum, subcmd_field_name));
                            subcmd_parsed = true;
                            tok.index = tok.args.len;
                            found_sub = true;
                        }
                    }
                }
                if (!found_sub) {
                    if (!try parser.handlePositional(T, config, &result, &field_set, &lists, &positional_index, val, allocator))
                        return if (positional_index > 0) error.TooManyPositionals else error.UnknownSubcommand;
                }
            },
            .end_of_options => {},
        }
    }

    // Mark multi fields as set before required-field check to prevent
    // leaking toOwnedSlice allocations when a required field is missing.
    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        if (comptime argKind(field.type, fc) == .multi) {
            field_set.insert(@field(FieldEnum, field.name));
        }
    }

    // Required-field check: uses else instead of continue because inline for
    // does not support continue in this context.
    inline for (fields) |field| {
        if (!field_set.contains(@field(FieldEnum, field.name))) {
            const fc = comptime getFieldConfig(config, field.name);
            const kind = comptime argKind(field.type, fc);
            if (kind == .subcommand and @typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            } else if (kind == .subcommand) {
                return error.MissingSubcommand;
            } else {
                return error.MissingRequired;
            }
        }
    }

    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        if (comptime argKind(field.type, fc) == .multi) {
            @field(result, field.name) = try @field(lists, field.name).toOwnedSlice(allocator);
        }
    }

    return result;
}

/// Retrieve the config for a subcommand variant at comptime.
/// The return type varies per variant, so callers infer it via anytype.
fn getSubVariantConfig(comptime config: anytype, comptime subcmd_field_name: []const u8, comptime variant_name: []const u8) SubVariantConfigType(config, subcmd_field_name, variant_name) {
    const Config = @TypeOf(config);
    const config_info = @typeInfo(Config);
    if (config_info != .@"struct") return .{};

    inline for (config_info.@"struct".fields) |cf| {
        if (comptime std.mem.eql(u8, cf.name, subcmd_field_name)) {
            const subcmd_config = @field(config, subcmd_field_name);
            const SubConfig = @TypeOf(subcmd_config);
            const sub_info = @typeInfo(SubConfig);
            if (sub_info != .@"struct") return .{};

            inline for (sub_info.@"struct".fields) |vf| {
                if (comptime std.mem.eql(u8, vf.name, variant_name)) {
                    return @field(subcmd_config, variant_name);
                }
            }
            return .{};
        }
    }
    return .{};
}

fn SubVariantConfigType(comptime config: anytype, comptime subcmd_field_name: []const u8, comptime variant_name: []const u8) type {
    const Config = @TypeOf(config);
    const config_info = @typeInfo(Config);
    if (config_info != .@"struct") return @TypeOf(.{});

    for (config_info.@"struct".fields) |cf| {
        if (std.mem.eql(u8, cf.name, subcmd_field_name)) {
            const subcmd_config = @field(config, subcmd_field_name);
            const SubConfig = @TypeOf(subcmd_config);
            const sub_info = @typeInfo(SubConfig);
            if (sub_info != .@"struct") return @TypeOf(.{});

            for (sub_info.@"struct".fields) |vf| {
                if (std.mem.eql(u8, vf.name, variant_name)) {
                    return @TypeOf(@field(subcmd_config, variant_name));
                }
            }
            return @TypeOf(.{});
        }
    }
    return @TypeOf(.{});
}

fn deinitSubcommand(
    comptime SubUnion: type,
    sub: *SubUnion,
    allocator: std.mem.Allocator,
    comptime config: anytype,
    comptime subcmd_field_name: []const u8,
) void {
    const sub_ufields = @typeInfo(SubUnion).@"union".fields;
    inline for (sub_ufields) |sf| {
        if (sub.* == @field(std.meta.FieldEnum(SubUnion), sf.name)) {
            const sub_config = comptime getSubVariantConfig(config, subcmd_field_name, sf.name);
            var payload = @field(sub, sf.name);
            parser.deinitResult(sf.type, &payload, allocator, sub_config);
            sub.* = @unionInit(SubUnion, sf.name, payload);
        }
    }
}

test "parse: basic flag" {
    const Cli = struct { verbose: bool = false };
    const result = try parse(Cli, std.testing.allocator, &.{"--verbose"}, .{});
    try std.testing.expect(result.verbose);
}

test "parse: string option with default" {
    const Cli = struct { output: []const u8 = "out.txt" };
    const result = try parse(Cli, std.testing.allocator, &.{ "--output", "file.txt" }, .{});
    try std.testing.expectEqualStrings("file.txt", result.output);
}

test "parse: required positional" {
    const Cli = struct { input: []const u8 };
    const result = try parse(Cli, std.testing.allocator, &.{"hello.txt"}, .{
        .input = .{ .positional = true },
    });
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
    });

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
    });

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

    const result = try parse(Cli, std.testing.allocator, &.{"--verbose"}, .{});
    try std.testing.expect(result.verbose);
    try std.testing.expect(result.command == null);
}

test "parse: optional field without explicit default" {
    const Cli = struct { config_path: ?[]const u8 };
    const result = try parse(Cli, std.testing.allocator, &.{}, .{});
    try std.testing.expect(result.config_path == null);
}

test "parse: optional field without explicit default with value" {
    const Cli = struct { config_path: ?[]const u8 };
    const result = try parse(Cli, std.testing.allocator, &.{ "--config-path", "cfg.toml" }, .{});
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

    const result = try parse(Cli, std.testing.allocator, &.{"--verbose"}, .{});
    try std.testing.expect(result.verbose);
    try std.testing.expect(result.command == null);
}

test "parse: deinit with multi field" {
    const Cli = struct { ports: []const u16 = &.{} };
    var result = try parse(Cli, std.testing.allocator, &.{ "--ports", "80", "--ports", "443" }, .{});
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
    });

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

    const result = try parse(Cli, std.testing.allocator, &.{ "--mode", "fast" }, .{});
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

    const result = parse(Cli, std.testing.allocator, &.{ "--ports", "80" }, .{});
    try std.testing.expectError(error.MissingSubcommand, result);
}

test "parse: deinit optional multi field" {
    const Cli = struct { ports: ?[]const u16 = null };
    var result = try parse(Cli, std.testing.allocator, &.{ "--ports", "80", "--ports", "443" }, .{});
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
    const result = try parse(Cli, std.testing.allocator, &.{ "--", "run" }, config);
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
    const result = try parse(Cli, std.testing.allocator, &.{ "--verbose", "--", "push" }, config);
    try std.testing.expect(result.verbose);
    try std.testing.expectEqualStrings("push", result.target);
    try std.testing.expect(result.command == null);
}

test "parse: too many positionals in subcommand path" {
    const Command = union(enum) { run: struct {} };
    const Cli = struct {
        input: []const u8,
        command: ?Command = null,
    };
    const config = .{
        .input = .{ .positional = true },
        .command = .{},
    };

    // "file.txt extra" — first positional fills input, second is excess
    const result = parse(Cli, std.testing.allocator, &.{ "file.txt", "extra" }, config);
    try std.testing.expectError(error.TooManyPositionals, result);
}

test "parse: unknown subcommand" {
    const Command = union(enum) { run: struct {} };
    const Cli = struct {
        command: Command,
    };
    const config = .{ .command = .{} };

    // "bogus" matches no subcommand and no positional field
    const result = parse(Cli, std.testing.allocator, &.{"bogus"}, config);
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
    const result = parse(Cli, std.testing.allocator, &.{ "--", "file.txt", "extra" }, config);
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
    const result = parse(Cli, std.testing.allocator, &.{ "install", "pkg-a", "pkg-b" }, config);
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
    const result = parse(Cli, std.testing.allocator, &.{ "install", "pkg-a" }, config);
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

    var result = try parse(Cli, std.testing.allocator, &.{ "install", "pkg-a", "pkg-b" }, config);
    // First deinit frees the allocation and resets via @unionInit writeback.
    deinit(Cli, &result, std.testing.allocator, config);
    // Second deinit must be safe (no double free) because payload was reset.
    deinit(Cli, &result, std.testing.allocator, config);
}

test {
    _ = @import("parser.zig");
    _ = @import("tokenizer.zig");
    _ = @import("errors.zig");
}
