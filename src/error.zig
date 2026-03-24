pub const ParseError = error{
    UnknownOption,
    MissingOptionValue,
    MissingRequiredOption,
    MissingRequiredPositional,
    UnexpectedArgument,
    DuplicateOption,
    InvalidValue,
};
