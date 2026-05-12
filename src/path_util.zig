const std = @import("std");
const builtin = @import("builtin");

/// Expands "~" to the user's home directory.
/// Uses the provided environment variable provider.
pub fn expandHome(allocator: std.mem.Allocator, environ: std.process.Environ, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "~")) {
        const home = environ.getAlloc(allocator, if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") catch |err| {
            if (err == error.EnvironmentVariableMissing) return try allocator.dupe(u8, path);
            return err;
        };
        defer allocator.free(home);
        
        var suffix = path[1..];
        // Skip leading slash in suffix if it exists (e.g., "~/path" -> "path")
        if (suffix.len > 0 and (suffix[0] == '/' or suffix[0] == '\\')) {
            suffix = suffix[1..];
        }
        
        return try std.fs.path.join(allocator, &.{ home, suffix });
    }
    return try allocator.dupe(u8, path);
}

/// Expands home directory and ensures forward slashes for cross-platform consistency.
pub fn expandHomeAndNormalize(allocator: std.mem.Allocator, environ: std.process.Environ, path: []const u8) ![]u8 {
    const expanded = try expandHome(allocator, environ, path);
    // Replace backslashes with forward slashes
    for (expanded) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return expanded;
}
