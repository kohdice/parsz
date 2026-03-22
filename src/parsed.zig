pub fn Parsed(comptime SchemaType: type) type {
    return struct {
        pub const parsz_schema = SchemaType;
    };
}
