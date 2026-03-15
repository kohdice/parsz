const parsz = @import("parsz");
const std = @import("std");

// Nested payload config has a typo ('targt' instead of 'target').
// usage() should detect this via recursive validation.
const RemoteCli = struct {
    target: []const u8,
};
const Command = union(enum) {
    remote: RemoteCli,
};
const T = struct {
    command: Command,
};

comptime {
    _ = parsz.usage(T, .{
        .command = .{ .remote = .{ .targt = .{ .positional = true } } },
    }, std.io.null_writer);
}

test "nested subcmd typo in usage should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
