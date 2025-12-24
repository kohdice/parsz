/// Runtime parse errors returned when the command spec is valid but the input is not.
/// This error set is intentionally small and does not carry extra diagnostics.
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
