// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const Config = @import("config.zig").Config;
const Folder = @import("config.zig").Folder;
const SshSession = @import("ssh.zig").SshSession;
const ChecksumDb = @import("checksum_db.zig").ChecksumDb;
const db_loc = @import("db_path.zig");
const Scanner = @import("scanner.zig").Scanner;
pub const Watcher = @import("watcher.zig").Watcher;
const checksum_db = @import("checksum_db.zig");
const ansi = @import("ansi.zig");

pub var ssh_mutex = std.Io.Mutex.init;

/// How often a long initial sync checkpoints its checksum database.
const checkpoint_interval_ns: u64 = 5 * std.time.ns_per_s;

pub const FolderSync = struct {
    folder: *const Folder,
    remote_db: ChecksumDb,
    remote_db_path: []const u8,
    /// Database files inside the synced tree (see `db_path`), used to keep
    /// databases out of scans, watch events and cleanup.
    db_rels: []const []const u8,
    watcher: Watcher,
};

pub fn performInitialSync(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    folder: *const Folder,
    ssh: *SshSession,
    remote_db: *ChecksumDb,
    remote_db_path: []const u8,
    /// True when no database existed yet for this folder. Used to persist an
    /// empty database for a folder that has nothing to upload.
    db_missing: bool,
    printer: ansi.Printer,
) !bool {
    var scanner = Scanner.init(allocator, io, config, folder);
    defer scanner.deinit();
    const db_rels = db_loc.relPathsInTree(allocator, io, config.folders, folder) catch &[_][]const u8{};
    defer db_loc.freeRelPaths(allocator, db_rels);
    try scanner.scanDirectory();
    if (config.verbose) std.debug.print("Found {} local files.\n", .{scanner.files.items.len});

    // Drop entries for files that no longer exist locally, so a deleted file or
    // folder cannot hide in the database forever.
    var present = std.StringHashMap(void).init(allocator);
    defer present.deinit();
    for (scanner.files.items) |entry| try present.put(entry.path, {});
    const pruned = remote_db.prune(&present);

    var changed_files = try scanner.getChangedFiles(remote_db);
    defer {
        for (changed_files.items) |entry| {
            allocator.free(entry.path);
        }
        changed_files.deinit(allocator);
    }

    if (changed_files.items.len == 0) {
        if ((pruned > 0 or db_missing) and !config.dry_run and !folder.no_db) {
            saveDatabaseLocked(allocator, io, config, folder, remote_db, ssh, remote_db_path, config.verbose) catch |err| {
                std.debug.print("Warning: could not persist pruned database: {s}\n", .{@errorName(err)});
            };
        }
        if (config.verbose) std.debug.print("Folder {s} is up to date!\n", .{folder.local_dir});
        return false;
    }

    std.debug.print("Uploading {} changed files for {s}...\n", .{ changed_files.items.len, folder.local_dir });

    // Uploads run over one SSH session, one file at a time. The bundled
    // libssh2 mbedtls backend keeps a process-global entropy/CTR_DRBG state
    // that every outgoing packet draws its padding from, so two sessions
    // sending at the same time race on it and corrupt memory (observed as
    // "Illegal instruction", heap corruption and crashes in
    // _libssh2_transport_send / session_free). `parallel_threads` therefore
    // parallelizes local scanning and hashing, not SSH transfers.
    // Files whose upload could not be completed must not enter the database,
    // otherwise the next run would consider them synced and skip them.
    var failed_uploads = std.StringHashMap(void).init(allocator);
    defer failed_uploads.deinit();

    var last_checkpoint_ns = std.Io.Timestamp.now(io, .boot).nanoseconds;
    for (changed_files.items, 1..) |entry, i| {
        if (config.dry_run) {
            std.debug.print("[{}/{}] Dry-run: Would sync: {s}\n", .{ i, changed_files.items.len, entry.path });
            continue;
        }

        std.debug.print("[{}/{}] Syncing: {s}\n", .{ i, changed_files.items.len, entry.path });
        syncFile(allocator, config, folder, ssh, entry.path) catch |err| switch (err) {
            error.UploadIncomplete, error.UploadCloseFailed => {
                failed_uploads.put(entry.path, {}) catch {};
                continue;
            },
            else => return err,
        };
        try remote_db.put(entry.path, entry.checksum, entry.mtime, entry.size);
        printer.printc(.yellow, "[{}/{}] Synced: {s}\n", .{ i, changed_files.items.len, entry.path });

        if (!folder.no_db) {
            const now = std.Io.Timestamp.now(io, .boot).nanoseconds;
            if (now - last_checkpoint_ns >= @as(i128, checkpoint_interval_ns)) {
                saveDatabase(allocator, io, config, folder, remote_db, ssh, remote_db_path, config.verbose) catch |err| {
                    std.debug.print("Warning: database checkpoint failed: {s}\n", .{@errorName(err)});
                };
                last_checkpoint_ns = now;
            }
        }
    }

    if (!config.dry_run) {
        // Re-populate the database with only current local files.
        // Keep this in memory even for `no_db` folders so watch mode can
        // compare content hashes without reading the remote filesystem.
        remote_db.clear();
        for (scanner.files.items) |entry| {
            if (failed_uploads.contains(entry.path)) continue;
            try remote_db.put(entry.path, entry.checksum, entry.mtime, entry.size);
        }

        if (!folder.no_db) {
            // Save updated database
            try ssh_mutex.lock(io);
            defer ssh_mutex.unlock(io);
            try saveDatabase(allocator, io, config, folder, remote_db, ssh, remote_db_path, true);
        }
    }

    // Initial Cleanup if requested
    if (config.cleanup) {
        var local_paths = std.StringHashMap(void).init(allocator);
        defer local_paths.deinit();
        for (scanner.files.items) |entry| {
            try local_paths.put(entry.path, {});
        }
        try performCleanup(allocator, config, folder, ssh, &local_paths, db_rels);
    }

    if (config.exec_cmd) |cmd| {
        if (config.dry_run) {
            std.debug.print("Dry-run: Would execute remote command after initial sync: {s}\n", .{cmd});
        } else {
            std.debug.print("Executing remote command after initial sync: {s}\n", .{cmd});
            ssh.exec(cmd) catch |err| {
                std.debug.print("Warning: Failed to execute remote command: {s}\n", .{@errorName(err)});
            };
        }
    }

    try performSyncTrigger(allocator, config, folder, ssh);
    try performVersionFileUpload(allocator, io, config, folder, ssh);

    return true;
}

pub fn performCleanup(
    allocator: std.mem.Allocator,
    config: *const Config,
    folder: *const Folder,
    ssh: *SshSession,
    local_files: *std.StringHashMap(void),
    db_rels: []const []const u8,
) !void {
    std.debug.print("Cleanup: Checking remote files for {s}...\n", .{folder.remote_dir});
    const remote_files = try ssh.listRemoteFilesRecursive(allocator, folder.remote_dir);
    defer {
        for (remote_files) |f| allocator.free(f);
        allocator.free(remote_files);
    }

    var removed_count: usize = 0;
    for (remote_files) |remote_full_path| {
        // Get relative path from remote_dir
        if (std.mem.startsWith(u8, remote_full_path, folder.remote_dir)) {
            var rel_path = remote_full_path[folder.remote_dir.len..];
            if (rel_path.len > 0 and rel_path[0] == '/') rel_path = rel_path[1..];

            // Normalize slashes for consistency
            // (Remote paths from SFTP should already use forward slashes)

            // Never delete the folder's own database file, wherever it lives.
            if (db_loc.matchesAnyDatabaseFile(rel_path, db_rels)) continue;

            // Check if it matches include/exclude
            if (shouldSyncFile(rel_path, folder, db_rels)) {
                // If it matches patterns but isn't in local_files, delete it
                if (!local_files.contains(rel_path)) {
                    if (config.dry_run) {
                        std.debug.print("Cleanup: Dry-run: Would remove remote file {s}\n", .{remote_full_path});
                    } else {
                        std.debug.print("Cleanup: Removing remote file {s}\n", .{remote_full_path});
                        try ssh.removeRemoteFile(remote_full_path);
                    }
                    removed_count += 1;
                }
            }
        }
    }
    if (removed_count > 0) {
        std.debug.print("Cleanup: Removed {} orphaned files.\n", .{removed_count});
    } else {
        std.debug.print("Cleanup: No orphaned files found.\n", .{});
    }
}

pub fn syncFile(
    allocator: std.mem.Allocator,
    config: *const Config,
    folder: *const Folder,
    ssh: *SshSession,
    rel_path: []const u8,
) !void {
    const local_path = try std.fs.path.join(allocator, &[_][]const u8{ folder.local_dir, rel_path });
    defer allocator.free(local_path);

    const remote_path_win = try std.fs.path.join(allocator, &[_][]const u8{ folder.remote_dir, rel_path });
    defer allocator.free(remote_path_win);

    // Ensure forward slashes for Linux
    const remote_path = try allocator.dupe(u8, remote_path_win);
    defer allocator.free(remote_path);
    std.mem.replaceScalar(u8, remote_path, '\\', '/');

    // Create remote directory if needed
    if (std.mem.lastIndexOfScalar(u8, remote_path, '/')) |last_slash| {
        const remote_dir = remote_path[0..last_slash];
        ssh.createRemoteDir(remote_dir) catch |err| {
            std.debug.print("Warning: Failed to create remote dir {s}: {s}\n", .{ remote_dir, @errorName(err) });
        };
    }

    // Upload file
    try ssh.uploadFile(local_path, remote_path, config.simple_log);
}

pub fn watchFolderThread(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    ssh: *SshSession,
    fs: *FolderSync,
    printer: ansi.Printer,
) void {
    var pending_syncs = std.StringHashMap(i64).init(allocator);
    defer {
        var it = pending_syncs.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        pending_syncs.deinit();
    }

    var ready_paths = std.ArrayList([]const u8).empty;
    defer ready_paths.deinit(allocator);

    while (true) {
        // Wait for events with a small timeout to allow processing of pending syncs
        fs.watcher.wait(100) catch {};

        // 1. Collect and merge new events
        while (true) {
            const event = fs.watcher.nextEvent() catch |err| {
                std.debug.print("Watcher error in {s}: {}\n", .{ fs.folder.local_dir, err });
                break;
            } orelse break;

            defer allocator.free(event.path);

            if (config.verbose) {
                std.debug.print("[{s}] event {s}: {s}\n", .{ fs.folder.local_dir, @tagName(event.kind), event.path });
            }

            if (event.kind == .created or event.kind == .modified) {
                if (!shouldSyncFile(event.path, fs.folder, fs.db_rels)) continue;

                const target_time = @as(i64, @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms))) + @as(i64, @intCast(config.watch_delay_ms));

                if (pending_syncs.getEntry(event.path)) |entry| {
                    entry.value_ptr.* = target_time;
                } else {
                    //                    std.debug.print("[{s}] Change detected (will sync after {}ms): {s}\n", .{ fs.folder.local_dir, config.watch_delay_ms, event.path });
                    const path_copy = allocator.dupe(u8, event.path) catch continue;
                    pending_syncs.put(path_copy, target_time) catch {
                        allocator.free(path_copy);
                    };
                }
            }
        }

        // 2. Identify ready files
        const now = @as(i64, @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms)));
        var it = pending_syncs.iterator();
        while (it.next()) |entry| {
            if (now >= entry.value_ptr.*) {
                ready_paths.append(allocator, entry.key_ptr.*) catch {};
            }
        }

        // 3. Process ready files
        for (ready_paths.items) |rel_path| {
            _ = pending_syncs.remove(rel_path);

            processReadySync(allocator, io, config, ssh, fs, rel_path, printer) catch |err| {
                std.debug.print("Error syncing {s}: {}\n", .{ rel_path, err });
            };

            allocator.free(rel_path);
        }
        ready_paths.clearRetainingCapacity();
    }
}

pub fn processReadySync(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    ssh: *SshSession,
    fs: *FolderSync,
    rel_path: []const u8,
    printer: ansi.Printer,
) !void {
    // The database file is metadata; uploading it would corrupt the remote
    // database (and, with `local_db`, would leak it into the synced tree).
    if (db_loc.matchesAnyDatabaseFile(rel_path, fs.db_rels)) return;

    const local_path = try std.fs.path.join(allocator, &[_][]const u8{ fs.folder.local_dir, rel_path });
    defer allocator.free(local_path);

    // Check if file still exists
    std.Io.Dir.cwd().access(io, local_path, .{}) catch return;

    // Check if actually a file and get mtime
    const stat = std.Io.Dir.cwd().statFile(io, local_path, .{}) catch return;
    if (stat.kind == .directory) {
        var normalized_rel = try allocator.dupe(u8, rel_path);
        defer allocator.free(normalized_rel);
        std.mem.replaceScalar(u8, normalized_rel, '\\', '/');
        if (normalized_rel.len > 0 and normalized_rel[0] == '/') {
            try ssh.createRemoteDir(normalized_rel[1..]);
        } else {
            try ssh.createRemoteDir(normalized_rel);
        }
        return;
    }
    const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));

    // Check if actually changed
    var is_changed = true;
    const is_text = checksum_db.isTextFile(rel_path, config.text_extensions);
    var checksum: u64 = 0;

    if (fs.folder.single_file) {
        // `[file]` tasks keep the last synced hash in memory so a touched but
        // unchanged file is skipped. The first sync still uploads defensively.
        checksum = try checksum_db.calculateFileChecksum(allocator, io, local_path, is_text);
        if (fs.remote_db.get(rel_path)) |old_entry| {
            is_changed = (old_entry.hash != checksum);
        }
    } else if (fs.folder.no_db) {
        if (try ssh.getFileInfo(rel_path)) |remote_info| {
            if (fs.folder.check == .mtime_size) {
                // Upload if local is newer, OR binary file changed size
                is_changed = mtime > remote_info.mtime or
                    (!is_text and stat.size != remote_info.size);
            } else {
                checksum = try checksum_db.calculateFileChecksum(allocator, io, local_path, is_text);
                // We don't have the remote hash easily without DB, so if check=hash and no_db,
                // we might have to assume it's changed or we need a way to store just the hash.
                // But the user said for no_db, mtime_size is preferable.
                // If they insist on hash check without DB, we'd have to download the remote file
                // and hash it, which is slow.
                // For now, let's assume if no_db and check=hash, we always upload
                // OR we just use mtime_size as fallback.
                is_changed = true;
            }
        }
    } else {
        if (fs.remote_db.get(rel_path)) |old_entry| {
            if (fs.folder.check == .mtime_size) {
                // Upload if local is newer, OR binary file changed size
                is_changed = mtime > old_entry.mtime or
                    (!is_text and stat.size != old_entry.size);
            } else {
                checksum = try checksum_db.calculateFileChecksum(allocator, io, local_path, is_text);
                is_changed = (old_entry.hash != checksum);
            }
        }
    }

    if (!is_changed) {
        std.debug.print("[{s}] No change detected: {s}\n", .{ fs.folder.local_dir, rel_path });
        return;
    }

    if (checksum == 0 and fs.folder.check == .hash) {
        checksum = try checksum_db.calculateFileChecksum(allocator, io, local_path, is_text);
    }

    std.debug.print("[{s}] Uploading: {s}\n", .{ fs.folder.local_dir, rel_path });

    try ssh_mutex.lock(io);
    defer ssh_mutex.unlock(io);

    if (config.dry_run) {
        std.debug.print("[{s}] Dry-run: Would upload: {s}\n", .{ fs.folder.local_dir, rel_path });
    } else {
        try syncFile(allocator, config, fs.folder, ssh, rel_path);

        // Always remember the hash for this process, even when no on-disk
        // database is used (`no_db` / `[file]`). This is what lets watch mode
        // skip a touched-but-unchanged file.
        try fs.remote_db.put(rel_path, checksum, mtime, stat.size);

        if (!fs.folder.no_db) {
            try saveDatabase(allocator, io, config, fs.folder, &fs.remote_db, ssh, fs.remote_db_path, true);
        }
    }

    if (config.exec_cmd) |cmd| {
        if (config.dry_run) {
            std.debug.print("[{s}] Dry-run: Would execute remote command: {s}\n", .{ fs.folder.local_dir, cmd });
        } else {
            std.debug.print("[{s}] Executing remote command: {s}\n", .{ fs.folder.local_dir, cmd });
            ssh.exec(cmd) catch |err| {
                std.debug.print("Warning: Failed to execute remote command: {s}\n", .{@errorName(err)});
            };
        }
    }

    try performSyncTrigger(allocator, config, fs.folder, ssh);
    try performVersionFileUpload(allocator, io, config, fs.folder, ssh);

    printer.printc(.yellow, "[{s}] Synced: {s}\n\n", .{ fs.folder.local_dir, rel_path });
}

pub fn shouldSyncFile(path: []const u8, folder: *const Folder, db_rels: []const []const u8) bool {
    // Database files are metadata, never content.
    if (db_loc.matchesAnyDatabaseFile(path, db_rels)) return false;
    for (folder.exclude_patterns) |pattern| {
        if (Scanner.matchPattern(path, pattern)) return false;
    }
    if (folder.include_patterns.len > 0) {
        for (folder.include_patterns) |pattern| {
            if (Scanner.matchPattern(path, pattern)) return true;
        }
        return false;
    }
    return true;
}

pub fn performSyncTrigger(
    allocator: std.mem.Allocator,
    config: *const Config,
    folder: *const Folder,
    ssh: *SshSession,
) !void {
    _ = allocator;
    const trigger_to = folder.trigger_to orelse return;

    if (folder.trigger_from) |trigger_from| {
        if (config.dry_run) {
            std.debug.print("[{s}] Dry-run: Would copy trigger file: {s} -> {s}\n", .{ folder.local_dir, trigger_from, trigger_to });
        } else {
            std.debug.print("[{s}] Copying trigger file: {s} -> {s}\n", .{ folder.local_dir, trigger_from, trigger_to });
            ssh.uploadFile(trigger_from, trigger_to, config.simple_log) catch |err| {
                std.debug.print("Warning: Failed to copy trigger file: {s}\n", .{@errorName(err)});
            };
        }
    } else {
        if (config.dry_run) {
            std.debug.print("[{s}] Dry-run: Would write empty trigger file: {s}\n", .{ folder.local_dir, trigger_to });
        } else {
            std.debug.print("[{s}] Writing empty trigger file: {s}\n", .{ folder.local_dir, trigger_to });
            ssh.uploadBuffer(&[_]u8{}, trigger_to, config.simple_log) catch |err| {
                std.debug.print("Warning: Failed to write empty trigger file: {s}\n", .{@errorName(err)});
            };
        }
    }
}

pub fn performVersionFileUpload(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    folder: ?*const Folder,
    ssh: *SshSession,
) !void {
    const v_from = if (folder) |f| f.version_from orelse config.version_from else config.version_from;
    const v_to = if (folder) |f| f.version_to orelse config.version_to else config.version_to;
    const v_name = if (folder) |f| f.version_name orelse config.version_name else config.version_name;

    const version_from = v_from orelse return;
    const version_to = v_to orelse return;

    const template_content = std.Io.Dir.cwd().readFileAlloc(io, version_from, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
        std.debug.print("Warning: Failed to read version template {s}: {s}\n", .{ version_from, @errorName(err) });
        return;
    };
    defer allocator.free(template_content);

    const now_secs = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);
    var ts_buf: [32]u8 = undefined;
    const ts_str = try std.fmt.bufPrint(&ts_buf, "{}", .{now_secs});

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    const is_json = std.mem.endsWith(u8, version_from, ".json");
    const is_ini = std.mem.endsWith(u8, version_from, ".ini");

    var found_timestamp = false;
    var found_name = false;

    var i: usize = 0;
    while (i < template_content.len) {
        if (std.mem.startsWith(u8, template_content[i..], "${timestamp}")) {
            try result.appendSlice(allocator, ts_str);
            i += "${timestamp}".len;
            found_timestamp = true;
            continue;
        }

        if (v_name) |vn| {
            if (std.mem.startsWith(u8, template_content[i..], "${version_name}")) {
                try result.appendSlice(allocator, vn);
                i += "${version_name}".len;
                found_name = true;
                continue;
            }

            if (std.mem.startsWith(u8, template_content[i..], "${name}")) {
                try result.appendSlice(allocator, vn);
                i += "${name}".len;
                found_name = true;
                continue;
            }

            if (is_json and std.mem.startsWith(u8, template_content[i..], "\"name\"")) {
                try result.appendSlice(allocator, "\"name\"");
                i += "\"name\"".len;
                // Skip whitespaces and colon
                while (i < template_content.len and (std.ascii.isWhitespace(template_content[i]) or template_content[i] == ':')) {
                    try result.append(allocator, template_content[i]);
                    i += 1;
                }
                // Skip optional starting quote
                var has_quote = false;
                if (i < template_content.len and template_content[i] == '\"') {
                    has_quote = true;
                    try result.append(allocator, '\"');
                    i += 1;
                }
                // Skip old value
                while (i < template_content.len and template_content[i] != '\"' and template_content[i] != ',' and template_content[i] != '}' and !std.ascii.isWhitespace(template_content[i])) {
                    i += 1;
                }
                try result.appendSlice(allocator, vn);
                if (has_quote and i < template_content.len and template_content[i] == '\"') {
                    try result.append(allocator, '\"');
                    i += 1;
                } else if (has_quote) {
                    try result.append(allocator, '\"');
                }
                found_name = true;
                continue;
            }

            if (is_ini and std.mem.startsWith(u8, template_content[i..], "name")) {
                const is_start = (i == 0 or template_content[i - 1] == '\n' or template_content[i - 1] == '\r');
                if (is_start) {
                    try result.appendSlice(allocator, "name");
                    i += "name".len;
                    // Skip whitespaces and equals
                    while (i < template_content.len and (std.ascii.isWhitespace(template_content[i]) or template_content[i] == '=')) {
                        try result.append(allocator, template_content[i]);
                        i += 1;
                    }
                    // Skip old value until newline
                    while (i < template_content.len and template_content[i] != '\n' and template_content[i] != '\r') {
                        i += 1;
                    }
                    try result.appendSlice(allocator, vn);
                    found_name = true;
                    continue;
                }
            }
        }

        if (std.mem.startsWith(u8, template_content[i..], "\"timestamp\"") and is_json) {
            try result.appendSlice(allocator, "\"timestamp\"");
            i += "\"timestamp\"".len;
            // Skip whitespaces and colon
            while (i < template_content.len and (std.ascii.isWhitespace(template_content[i]) or template_content[i] == ':')) {
                try result.append(allocator, template_content[i]);
                i += 1;
            }
            // Skip digits of the old timestamp
            while (i < template_content.len and std.ascii.isDigit(template_content[i])) {
                i += 1;
            }
            try result.appendSlice(allocator, ts_str);
            found_timestamp = true;
            continue;
        }

        if (is_ini and std.mem.startsWith(u8, template_content[i..], "timestamp")) {
            // Check if it's the start of a line or after a newline
            const is_start = (i == 0 or template_content[i - 1] == '\n' or template_content[i - 1] == '\r');
            if (is_start) {
                try result.appendSlice(allocator, "timestamp");
                i += "timestamp".len;
                // Skip whitespaces and equals
                while (i < template_content.len and (std.ascii.isWhitespace(template_content[i]) or template_content[i] == '=')) {
                    try result.append(allocator, template_content[i]);
                    i += 1;
                }
                // Skip digits of the old timestamp
                while (i < template_content.len and std.ascii.isDigit(template_content[i])) {
                    i += 1;
                }
                try result.appendSlice(allocator, ts_str);
                found_timestamp = true;
                continue;
            }
        }

        // Special case for JSON: if we hit the LAST closing brace and haven't added fields, add them
        if (is_json and template_content[i] == '}' and i == template_content.len - 1) {
            if (!found_name and v_name != null) {
                // If the result already has content beyond just '{', add a comma
                if (result.items.len > 1) try result.appendSlice(allocator, ", ");
                try result.appendSlice(allocator, "\"name\": \"");
                try result.appendSlice(allocator, v_name.?);
                try result.append(allocator, '\"');
                found_name = true;
            }
            if (!found_timestamp) {
                if (result.items.len > 1) try result.appendSlice(allocator, ", ");
                try result.appendSlice(allocator, "\"timestamp\": ");
                try result.appendSlice(allocator, ts_str);
                found_timestamp = true;
            }
        }

        try result.append(allocator, template_content[i]);
        i += 1;
    }

    if (folder) |f| {
        if (config.dry_run) {
            std.debug.print("[{s}] Dry-run: Would upload version file: {s} -> {s} (ts={})\n", .{ f.local_dir, version_from, version_to, now_secs });
        } else {
            std.debug.print("[{s}] Uploading version file: {s} -> {s} (ts={})\n", .{ f.local_dir, version_from, version_to, now_secs });
            ssh.uploadBuffer(result.items, version_to, config.simple_log) catch |err| {
                std.debug.print("Warning: Failed to upload version file: {s}\n", .{@errorName(err)});
            };
        }
    } else {
        if (config.dry_run) {
            std.debug.print("Dry-run: Would upload global version file: {s} -> {s} (ts={})\n", .{ version_from, version_to, now_secs });
        } else {
            std.debug.print("Uploading global version file: {s} -> {s} (ts={})\n", .{ version_from, version_to, now_secs });
            ssh.uploadBuffer(result.items, version_to, config.simple_log) catch |err| {
                std.debug.print("Warning: Failed to upload version file: {s}\n", .{@errorName(err)});
            };
        }
    }
}

pub fn saveDatabase(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    folder: *const Folder,
    db: *ChecksumDb,
    ssh: *SshSession,
    db_path: []const u8,
    announce: bool,
) !void {
    if (folder.no_db) return;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try db.serialize(&aw.writer);

    try saveDatabaseData(allocator, io, config, folder, aw.writer.buffer[0..aw.writer.end], ssh, db_path, announce);
}

/// Save the database, taking the shared SSH session lock only for a remote
/// database (a local database write does not touch the session).
pub fn saveDatabaseLocked(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    folder: *const Folder,
    db: *ChecksumDb,
    ssh: *SshSession,
    db_path: []const u8,
    announce: bool,
) !void {
    if (!folder.local_db) {
        try ssh_mutex.lock(io);
        defer ssh_mutex.unlock(io);
    }
    try saveDatabase(allocator, io, config, folder, db, ssh, db_path, announce);
}

/// Write or upload an already-serialized database. Used both by the final save
/// and by periodic checkpoints during a long initial sync.
///
/// `db_path` is the single resolved database location produced by
/// `db_path.resolve`, so the load and the save can never disagree about where
/// a folder keeps its database.
fn saveDatabaseData(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    folder: *const Folder,
    data: []const u8,
    ssh: *SshSession,
    db_path: []const u8,
    announce: bool,
) !void {
    if (folder.no_db) return;
    if (db_path.len == 0) return error.MissingDatabasePath;

    if (folder.local_db) {
        if (announce) std.debug.print("[{s}] Saving database locally to {s}...\n", .{ folder.local_dir, db_path });
        std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(db_path) orelse ".") catch {};

        // Write a sibling temp file first so a crash cannot truncate the
        // previous good database.
        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{db_path});
        defer allocator.free(tmp_path);

        {
            const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
            defer file.close(io);
            var write_buf: [4096]u8 = undefined;
            var file_writer = file.writer(io, &write_buf);
            try file_writer.interface.writeAll(data);
            try file_writer.interface.flush();
        }
        try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), db_path, io);
    } else {
        if (announce) std.debug.print("[{s}] Uploading database to {s}...\n", .{ folder.local_dir, db_path });

        // A custom database path may point at a directory that does not exist
        // yet (e.g. `scpdb = /var/lib/sync/app.scpdb`).
        if (std.fs.path.dirname(db_path)) |parent| {
            if (parent.len > 0 and !std.mem.eql(u8, parent, "/") and !std.mem.eql(u8, parent, ".")) {
                ssh.createRemoteDir(parent) catch {};
            }
        }

        // Upload to a temp path, then rename over the live database.
        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{db_path});
        defer allocator.free(tmp_path);

        try ssh.uploadBuffer(data, tmp_path, config.simple_log);
        ssh.renameRemoteFile(tmp_path, db_path) catch |err| {
            std.debug.print("Warning: database rename failed ({s}); writing directly to {s}\n", .{ @errorName(err), db_path });
            try ssh.uploadBuffer(data, db_path, config.simple_log);
        };
    }
}
