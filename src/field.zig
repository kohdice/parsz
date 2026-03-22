pub const FieldKind = enum {
    flag,
    option,
    positional,
    subcommand,
};

pub const FieldMeta = struct {
    long: ?[]const u8 = null,
    short: ?u8 = null,
    help: ?[]const u8 = null,
    value_name: ?[]const u8 = null,
};

pub fn Flag(comptime spec: FieldMeta) type {
    return struct {
        pub const parsz_kind: FieldKind = .flag;
        pub const ParsedValue = bool;
        pub const meta = spec;
    };
}

pub fn Option(comptime ValueType: type, comptime spec: FieldMeta) type {
    return struct {
        pub const parsz_kind: FieldKind = .option;
        pub const ParsedValue = ValueType;
        pub const meta = spec;
    };
}

pub fn Positional(comptime ValueType: type, comptime spec: FieldMeta) type {
    return struct {
        pub const parsz_kind: FieldKind = .positional;
        pub const ParsedValue = ValueType;
        pub const meta = spec;
    };
}

pub fn Subcommand(comptime ValueType: type) type {
    return struct {
        pub const parsz_kind: FieldKind = .subcommand;
        pub const ParsedValue = ValueType;
        pub const meta = FieldMeta{};
    };
}
