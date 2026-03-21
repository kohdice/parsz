const parsz = @import("parsz");
const std = @import("std");

const Command = union(enum) { run: u8 };
const T = struct { cmd: Command };

comptime {
    _ = parsz.help(T, .{}, std.io.null_writer);
}

test "non-struct subcommand payload rejected" {}
