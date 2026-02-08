/// Diagnostic information populated when a parse error occurs.
///
/// All slices are non-owning references to either argv memory or comptime
/// string literals, so no allocation or deallocation is needed.
/// Lifetime (per field):
/// - arg_name: always a comptime literal (static lifetime).
/// - flag_name: for known long options/flags (parser), comptime literal (static);
///   for known short options/flags (parser), argv slice (argv lifetime);
///   for unknown flags, argv slice (argv lifetime).
///   In validator errors (MissingRequired/InvalidValue), always comptime (static).
/// - provided_value: always an argv slice when non-empty (argv lifetime).
///
/// When `null` is passed as the diagnostic parameter, error reporting is
/// skipped with zero overhead — no fields are populated.
///
/// Note: `error.OutOfMemory` does NOT populate Diagnostic fields.
///
/// Field population per error variant:
/// | Error             | arg_name | flag_name | provided_value |
/// |-------------------|----------|-----------|----------------|
/// | UnknownFlag       |          | x         |                |
/// | MissingValue      | x        | x         |                |
/// | MissingRequired   | x        | x (*)     |                |
/// | InvalidValue      | x        | x (*)     | x              |
/// | TooManyPositionals| x        |           | x              |
/// | DuplicateArg      | x        | x         | x              |
///
/// (*) flag_name is set for option/flag kinds; empty for positionals.
///
/// Usage:
/// ```
/// var diagnostic: Diagnostic = .{};
/// const result = parsz.parse(allocator, argv, cmd, &diagnostic) catch |err| {
///     // diagnostic fields are now populated
/// };
/// ```
pub const Diagnostic = struct {
    /// The Arg.name from the command definition that caused the error.
    /// Empty if the error is for an unknown flag (no matching definition).
    arg_name: []const u8 = "",
    /// The flag/option name relevant to the error.
    /// For unknown flags: a slice from the argv element (argv lifetime).
    /// For known long options/flags (parser): comptime literal (static lifetime).
    /// For known short options/flags (parser): a 1-byte slice from the argv
    ///   element (argv lifetime), e.g., "o" for -o.
    /// For validator errors (MissingRequired/InvalidValue): comptime literal (static).
    /// For positionals: empty string.
    flag_name: []const u8 = "",
    /// The value string that caused the error (e.g., "abc" for --count=abc).
    provided_value: []const u8 = "",
};

/// Runtime parse errors returned when the command spec is valid but the input is not.
pub const ParseError = error{
    /// An undefined option was provided.
    /// Example: -x / --unknown
    UnknownFlag,

    /// An option that requires a value was given without one.
    /// Example: --output <value> with the value missing
    MissingValue,

    /// A required argument was not provided.
    /// This can happen for both option and positional arguments.
    MissingRequired,

    /// Type conversion failed, or a flag received a value.
    /// Example: --count=abc, --flag=value
    InvalidValue,

    /// Too many positional arguments were supplied.
    /// This occurs when there is no trailing "multiple" positional.
    TooManyPositionals,

    /// An option with multiple=false was specified more than once.
    /// Example: --output a --output b
    DuplicateArg,
};
