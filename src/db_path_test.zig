// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const db_path = @import("db_path.zig");
const Folder = @import("config.zig").Folder;

fn makeFolder(local_dir: []const u8, remote_dir: []const u8, scpdb: []const u8, local_db: bool) Folder {
    return .{
        .scpdb = scpdb,
        .local_db = local_db,
        .local_dir = local_dir,
        .remote_dir = remote_dir,
        .include_patterns = &[_][]const u8{},
        .exclude_patterns = &[_][]const u8{},
        .trigger_from = null,
        .trigger_to = null,
        .version_from = null,
        .version_to = null,
        .version_name = null,
    };
}

test "db_path: remote database is relative to remote_dir" {
    const allocator = std.testing.allocator;
    const folder = makeFolder("./src", "/srv/src", ".scpdb", false);

    const resolved = try db_path.resolve(allocator, &folder);
    defer allocator.free(resolved.path);
    try std.testing.expectEqual(db_path.Kind.remote, resolved.kind);
    try std.testing.expectEqualStrings("/srv/src/.scpdb", resolved.path);

    const rel = try db_path.relPathInTree(allocator, std.testing.io, &folder);
    defer if (rel) |p| allocator.free(p);
    try std.testing.expectEqualStrings(".scpdb", rel.?);
}

test "db_path: absolute remote database is used as-is" {
    const allocator = std.testing.allocator;
    // DOCUMENTATION.md: local_db=false + absolute scpdb -> absolute path on the
    // remote host. It must not be joined onto remote_dir.
    const folder = makeFolder("./src", "/srv/src", "/var/lib/sync/app.scpdb", false);

    const resolved = try db_path.resolve(allocator, &folder);
    defer allocator.free(resolved.path);
    try std.testing.expectEqual(db_path.Kind.remote, resolved.kind);
    try std.testing.expectEqualStrings("/var/lib/sync/app.scpdb", resolved.path);

    const rel = try db_path.relPathInTree(allocator, std.testing.io, &folder);
    try std.testing.expect(rel == null);
}

test "db_path: local database is relative to local_dir" {
    const allocator = std.testing.allocator;
    const folder = makeFolder("src", "./src", "meta/app.scpdb", true);

    const resolved = try db_path.resolve(allocator, &folder);
    defer allocator.free(resolved.path);
    try std.testing.expectEqual(db_path.Kind.local, resolved.kind);
    try std.testing.expectEqualStrings("src/meta/app.scpdb", resolved.path);

    const rel = try db_path.relPathInTree(allocator, std.testing.io, &folder);
    defer if (rel) |p| allocator.free(p);
    try std.testing.expectEqualStrings("meta/app.scpdb", rel.?);
}

test "db_path: local absolute database inside the tree is excluded" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    try std.Io.Dir.cwd().createDirPath(io, "test_db_tree/meta");
    defer std.Io.Dir.cwd().deleteTree(io, "test_db_tree") catch {};

    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, "test_db_tree", allocator);
    defer allocator.free(root);

    const inside = try std.fs.path.join(allocator, &[_][]const u8{ root, "meta/app.scpdb" });
    defer allocator.free(inside);

    var folder = makeFolder(root, "./src", inside, true);
    const rel = try db_path.relPathInTree(allocator, io, &folder);
    defer if (rel) |p| allocator.free(p);
    try std.testing.expectEqualStrings("meta/app.scpdb", rel.?);

    const resolved = try db_path.resolve(allocator, &folder);
    defer allocator.free(resolved.path);
    try std.testing.expectEqual(db_path.Kind.local, resolved.kind);

    // A database outside the tree is not part of the sync.
    folder.scpdb = "/somewhere/else/app.scpdb";
    const outside = try db_path.relPathInTree(allocator, io, &folder);
    try std.testing.expect(outside == null);
}

test "db_path: nested folder databases are reserved in the parent tree" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    try std.Io.Dir.cwd().createDirPath(io, "test_nested_tree/src");
    defer std.Io.Dir.cwd().deleteTree(io, "test_nested_tree") catch {};

    var folders = [_]Folder{
        makeFolder("test_nested_tree", "/srv/root", ".scpdb", true),
        makeFolder("test_nested_tree/src", "/srv/src", ".scpdb", true),
    };

    const rels = try db_path.relPathsInTree(allocator, io, &folders, &folders[0]);
    defer db_path.freeRelPaths(allocator, rels);

    try std.testing.expectEqual(@as(usize, 2), rels.len);
    try std.testing.expect(db_path.matchesAnyDatabaseFile(".scpdb", rels));
    try std.testing.expect(db_path.matchesAnyDatabaseFile("src/.scpdb", rels));
    try std.testing.expect(!db_path.matchesAnyDatabaseFile("src/app.class", rels));
}

test "db_path: database files are recognized, content files are not" {
    try std.testing.expect(db_path.isDatabaseFile(".scpdb", ".scpdb"));
    try std.testing.expect(db_path.isDatabaseFile(".scpdb.tmp", ".scpdb"));
    try std.testing.expect(db_path.isDatabaseFile("meta\\app.scpdb", "meta/app.scpdb"));
    try std.testing.expect(!db_path.isDatabaseFile("app.scpdb", ".scpdb"));
    try std.testing.expect(!db_path.isDatabaseFile(".scpdb", null));
    try std.testing.expect(!db_path.isDatabaseFile(".scpdb", ""));
}
