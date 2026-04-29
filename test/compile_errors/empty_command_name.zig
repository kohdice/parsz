const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "",
    .args = .{},
});

test "schema error" {
    _ = Cli;
}
