const parsz = @import("parsz");

// bool + .positional = true is invalid: bool fields are always flags.
const T = struct {
    flag: bool = false,
};

comptime {
    _ = parsz.help(T, .{
        .flag = .{ .positional = true },
    }, @import("std").io.null_writer);
}

test "bool positional should fail at comptime" {}
