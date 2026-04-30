pub const ParseError = error{
    ParseFailed,
    OutOfMemory,
};

pub const ParseErrorKind = enum {
    unknown_option,
    missing_value,
    unexpected_value,
    invalid_value,
    overflow,
    missing_required,
    unexpected_operand,
    ambiguous_abbreviation,
    unknown_subcommand,
};

pub const Diagnostic = struct {
    kind: ParseErrorKind,
    argv_index: ?usize = null,
    cluster_offset: ?usize = null,
    arg_name: ?[]const u8 = null,
    raw_arg: ?[]const u8 = null,
    value: ?[]const u8 = null,
};

pub const ParseOptions = struct {
    diagnostic: ?*Diagnostic = null,
    abbreviate_long_options: bool = false,
};

pub fn failWithDiagnostic(options: ParseOptions, diagnostic_value: Diagnostic) ParseError {
    if (options.diagnostic) |diagnostic| {
        diagnostic.* = diagnostic_value;
    }

    return error.ParseFailed;
}
