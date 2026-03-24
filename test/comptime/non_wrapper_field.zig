// expected-error: error: parsz schema error at non_wrapper_field.Cli.verbose: expected a parsz schema wrapper, found bool

const parsz = @import("parsz");

const Cli = struct {
    verbose: bool,
};

comptime {
    _ = parsz.Parsed(Cli);
}
