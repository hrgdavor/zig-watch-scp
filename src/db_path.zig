// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const builtin = @import("builtin");
const Folder = @import("config.zig").Folder;

pub const Kind = enum { local, remote };

pub const Resolved = struct {
    /// Filesystem path for `.local`, POSIX path on the server for `.remote`.
    /// Owned by the caller.
    path: []const u8,
    kind: Kind,
};

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

fn isWindows() bool {
    return builtin.os.tag == .windows;
}

/// Canonical form used for database locations: forward slashes, no leading
/// `./`, no duplicate separators and no trailing separator. Windows drive
/// letters are upper-cased so paths from a config compare equal to paths
/// returned by `realPathFileAlloc`.
pub fn normalize(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') {
        try out.append(allocator, std.ascii.toUpper(path[0]));
        try out.append(allocator, ':');
        i = 2;
    } else if (path.len > 0 and isSep(path[0])) {
        try out.append(allocator, '/');
        i = 1;
    }
    // Drop any leading "./" (but never a leading "..").
    while (i + 1 < path.len and path[i] == '.' and isSep(path[i + 1])) i += 2;

    var prev_sep = false;
    while (i < path.len) : (i += 1) {
        const c = path[i];
        if (isSep(c)) {
            if (prev_sep) continue;
            prev_sep = true;
            try out.append(allocator, '/');
        } else {
            prev_sep = false;
            try out.append(allocator, c);
        }
    }

    var len = out.items.len;
    while (len > 1 and out.items[len - 1] == '/') len -= 1;
    out.shrinkRetainingCapacity(len);
    return out.toOwnedSlice(allocator);
}

/// Resolve where a folder's checksum database lives.
///
/// * `local_db = true`  -> on this machine, relative to `local_dir`.
/// * `local_db = false` -> on the remote host, relative to `remote_dir`.
///
/// An absolute `scpdb` is used as-is, as documented in DOCUMENTATION.md.
pub fn resolve(allocator: std.mem.Allocator, folder: *const Folder) !Resolved {
    if (!folder.local_db) {
        if (std.fs.path.isAbsolute(folder.scpdb)) {
            return .{ .path = try normalize(allocator, folder.scpdb), .kind = .remote };
        }
        const joined = try std.fs.path.join(allocator, &[_][]const u8{ folder.remote_dir, folder.scpdb });
        defer allocator.free(joined);
        return .{ .path = try normalize(allocator, joined), .kind = .remote };
    }

    if (std.fs.path.isAbsolute(folder.scpdb)) {
        return .{ .path = try normalize(allocator, folder.scpdb), .kind = .local };
    }
    const resolved = try std.fs.path.resolve(allocator, &[_][]const u8{ folder.local_dir, folder.scpdb });
    defer allocator.free(resolved);
    return .{ .path = try normalize(allocator, resolved), .kind = .local };
}

fn prefixEqual(root: []const u8, path: []const u8) bool {
    const head = path[0..root.len];
    return if (isWindows()) std.ascii.eqlIgnoreCase(head, root) else std.mem.eql(u8, head, root);
}

/// Path of the database file relative to the synchronized tree, or `null`
/// when the database lives outside of it (or no database is used).
///
/// The return value is always allocated. The same relative path is used both
/// locally and on the remote side, which is what allows the scanner, watcher
/// and cleanup to recognize the database file and never treat it as content.
pub fn relPathInTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    folder: *const Folder,
) !?[]const u8 {
    if (folder.no_db) return null;

    if (!folder.local_db) {
        if (std.fs.path.isAbsolute(folder.scpdb)) return null;
        const norm = try normalize(allocator, folder.scpdb);
        if (norm.len == 0 or std.mem.startsWith(u8, norm, "..")) {
            allocator.free(norm);
            return null;
        }
        return norm;
    }

    if (!std.fs.path.isAbsolute(folder.scpdb)) {
        const norm = try normalize(allocator, folder.scpdb);
        if (norm.len == 0 or std.mem.startsWith(u8, norm, "..")) {
            allocator.free(norm);
            return null;
        }
        return norm;
    }

    const root_abs = std.Io.Dir.cwd().realPathFileAlloc(io, folder.local_dir, allocator) catch return null;
    defer allocator.free(root_abs);
    const root = try normalize(allocator, root_abs);
    defer allocator.free(root);
    const db = try normalize(allocator, folder.scpdb);
    defer allocator.free(db);

    if (db.len <= root.len + 1) return null;
    if (!prefixEqual(root, db)) return null;
    if (db[root.len] != '/') return null;
    return try allocator.dupe(u8, db[root.len + 1 ..]);
}

fn pathEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x == y) continue;
        if (isSep(x) and isSep(y)) continue;
        if (isWindows() and std.ascii.toLower(x) == std.ascii.toLower(y)) continue;
        return false;
    }
    return true;
}

/// True when `rel_path` is the folder's database file (or the temporary
/// sibling written by the atomic database save).
pub fn isDatabaseFile(rel_path: []const u8, db_rel: ?[]const u8) bool {
    const db = db_rel orelse return false;
    if (db.len == 0) return false;
    if (pathEql(rel_path, db)) return true;
    return rel_path.len == db.len + 4 and
        std.mem.endsWith(u8, rel_path, ".tmp") and
        pathEql(rel_path[0..db.len], db);
}

pub fn matchesAnyDatabaseFile(rel_path: []const u8, db_rels: []const []const u8) bool {
    for (db_rels) |db| {
        if (isDatabaseFile(rel_path, db)) return true;
    }
    return false;
}

fn appendUnique(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) {
            allocator.free(value);
            return;
        }
    }
    try list.append(allocator, value);
}

/// Every database file that lives inside `tree.local_dir`, as paths relative to
/// it, including databases of other configured folders nested below it.
///
/// A scanner, watcher or cleanup pass uses this so that no folder's database is
/// ever uploaded as ordinary content (which would put a `.scpdb` into a synced
/// tree and would let one folder overwrite another folder's database).
/// The caller owns the result; free it with `freeRelPaths`.
pub fn relPathsInTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    folders: []const Folder,
    tree: *const Folder,
) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }

    // This folder's own database.
    if (try relPathInTree(allocator, io, tree)) |own| {
        try appendUnique(allocator, &list, own);
    }

    // Local databases of other folders that happen to sit inside this tree.
    const tree_abs = std.Io.Dir.cwd().realPathFileAlloc(io, tree.local_dir, allocator) catch null;
    if (tree_abs) |raw_root| {
        defer allocator.free(raw_root);
        const root = try normalize(allocator, raw_root);
        defer allocator.free(root);

        for (folders) |*folder| {
            if (folder.no_db or !folder.local_db) continue;

            const dir_abs = std.Io.Dir.cwd().realPathFileAlloc(io, folder.local_dir, allocator) catch continue;
            defer allocator.free(dir_abs);
            const dir = try normalize(allocator, dir_abs);
            defer allocator.free(dir);

            const db = if (std.fs.path.isAbsolute(folder.scpdb))
                try normalize(allocator, folder.scpdb)
            else blk: {
                const joined = try std.fs.path.join(allocator, &[_][]const u8{ dir, folder.scpdb });
                defer allocator.free(joined);
                break :blk try normalize(allocator, joined);
            };
            defer allocator.free(db);

            if (db.len <= root.len + 1) continue;
            if (!prefixEqual(root, db)) continue;
            if (db[root.len] != '/') continue;

            try appendUnique(allocator, &list, try allocator.dupe(u8, db[root.len + 1 ..]));
        }
    }

    return list.toOwnedSlice(allocator);
}

pub fn freeRelPaths(allocator: std.mem.Allocator, list: []const []const u8) void {
    if (list.len == 0) return;
    for (list) |p| allocator.free(p);
    allocator.free(@constCast(list));
}
