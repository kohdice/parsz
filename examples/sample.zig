const std = @import("std");
const parsz = @import("parsz");

pub fn main() void {
    const result = parsz.add(3, 7);
    std.debug.print("3 + 7 = {}\n", .{result});
}
