const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .version = parsz.version(.{ .number = "1.0.0", .details =
        \\Copyright (C) 2026 parsz contributors
        \\License MIT: MIT License <https://opensource.org/licenses/MIT>
    }),
    .args = .{
        .version = parsz.flag(.{ .long = "version" }),
    },
});

test "schema error" {
    _ = Cli;
}
