//! Keyword arg name test - ensures Zig keywords are accepted as Arg.name.

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "keyword-test",
        .args = &.{
            .{ .name = "type", .kind = .option, .long = "type", .required = true },
            .{ .name = "error", .kind = .positional },
        },
    };
    // ParseResult() calls validateCommand() internally at comptime.
    // This confirms keyword names do not trigger @compileError.
    _ = parsz.ParseResult(cmd);
}

test "keyword arg names compile" {
    // This test just needs to compile - the comptime block above does the validation
}
