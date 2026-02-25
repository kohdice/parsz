const parsz = @import("parsz");
const std = @import("std");

// Optional wrapping an untagged union should also trigger a compile error.
const BadUnion = union {
    a: i32,
    b: f64,
};

const T = struct {
    cmd: ?BadUnion = null,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{}, null);
}

test "optional untagged union field should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
