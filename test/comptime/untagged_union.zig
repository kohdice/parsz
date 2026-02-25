const parsz = @import("parsz");
const std = @import("std");

// Untagged union used as a field type should trigger a compile error
// because subcommand fields require tagged unions (union(enum)).
const BadUnion = union {
    a: i32,
    b: f64,
};

const T = struct {
    cmd: BadUnion,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{}, null);
}

test "untagged union field should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
