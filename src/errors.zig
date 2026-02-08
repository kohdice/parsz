/// Diagnostic information populated when a parse error occurs.
///
/// All slices are non-owning references to either argv memory or comptime
/// string literals, so no allocation or deallocation is needed.
/// Lifetime (per field):
/// - arg_name: always a comptime literal (static lifetime).
/// - flag_name: for known long options/flags (parser), comptime literal (static);
///   for known short options/flags (parser), argv slice (argv lifetime);
///   for unknown flags, argv slice (argv lifetime).
///   In validator errors (MissingRequired/InvalidValue/ValueOutOfRange), always comptime (static).
/// - provided_value: when non-empty, always an argv slice (argv lifetime);
///   when empty (default ""), a comptime literal (static lifetime).
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
/// | ValueOutOfRange   | x        | x (*)     | x              |
/// | TooManyPositionals| x (**)   |           | x              |
/// | DuplicateArg      | x        | x         | x              |
///
/// (*) flag_name is set for option/flag kinds; empty for positionals.
/// (**) arg_name is set to the last positional arg's name when positional
///      definitions exist; empty when the command has no positional definitions.
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
    /// Empty if the error is for an unknown flag (no matching definition)
    /// or for TooManyPositionals when no positional arguments are defined.
    arg_name: []const u8 = "",
    /// The flag/option name relevant to the error.
    /// For unknown flags: a slice from the argv element (argv lifetime).
    /// For known long options/flags (parser): comptime literal (static lifetime).
    /// For known short options/flags (parser): a 1-byte slice from the argv
    ///   element (argv lifetime), e.g., "o" for -o.
    /// For validator errors (MissingRequired/InvalidValue/ValueOutOfRange): comptime literal (static).
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

    /// An option was given without its value.
    /// Example: --output (with no following argument)
    MissingValue,

    /// A required argument was not provided.
    /// This can happen for both option and positional arguments.
    MissingRequired,

    /// Type conversion failed, or a flag received a value.
    /// Example: --count=abc, --flag=value
    InvalidValue,

    /// A numeric value was syntactically valid but exceeded the target type's range.
    /// Example: --count=99999999999999999999 (exceeds i64 range)
    ValueOutOfRange,

    /// Too many positional arguments were supplied.
    /// This occurs when there is no trailing "multiple" positional.
    TooManyPositionals,

    /// An option with multiple=false was specified more than once.
    /// Example: --output a --output b
    /// Note: Flags are idempotent and never produce DuplicateArg.
    /// Excess positional arguments produce TooManyPositionals instead.
    DuplicateArg,
};
