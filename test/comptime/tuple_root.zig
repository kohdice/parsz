// expected-error: tuple command schemas are not supported

const parsz = @import("parsz");

const Cli = struct {
    parsz.Flag(.{}),
};

comptime {
    _ = parsz.Parsed(Cli);
}
