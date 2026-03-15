const parsz = @import("parsz");
const std = @import("std");

// A subcommand variant payload contains an untagged union, which is invalid.
// The variant has NO explicit config entry, so only Phase B catches this.
const BadPayload = struct {
    value: union { a: i32, b: f64 },
};

const Command = union(enum) {
    good: struct {},
    bad: BadPayload,
};

const T = struct {
    command: ?Command = null,
};

comptime {
    _ = parsz.usage(T, .{}, std.io.null_writer);
}

test "unconfigured variant payload validated by usage" {}
