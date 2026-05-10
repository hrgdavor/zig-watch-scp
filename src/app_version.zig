const std = @import("std");
const build_options = @import("config");

pub fn printHeader(name: []const u8) void {
    std.debug.print("{s} {s}\n", .{ name, build_options.version });
}
