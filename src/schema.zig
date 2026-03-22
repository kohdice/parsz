pub const RootCommandMeta = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    about: ?[]const u8 = null,
};

pub const SubcommandMeta = struct {
    about: ?[]const u8 = null,
};

pub fn validateSchema(comptime SchemaType: type) void {
    _ = SchemaType;
}
