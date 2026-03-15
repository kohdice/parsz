const parsz = @import("parsz");
const std = @import("std");

// Deeply nested variant config is an integer instead of a struct.
const AddCli = struct {
    name: []const u8,
};
const RemoteCommand = union(enum) {
    add: AddCli,
};
const RemoteCli = struct {
    subcmd: RemoteCommand,
};
const Command = union(enum) {
    remote: RemoteCli,
};
const T = struct {
    command: Command,
};

comptime {
    _ = parsz.help(T, .{
        .command = .{ .remote = .{ .subcmd = .{ .add = 123 } } },
    }, std.io.null_writer);
}

test "nested subcmd variant int in help should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
