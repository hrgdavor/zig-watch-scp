// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const Config = @import("config.zig").Config;
const Folder = @import("config.zig").Folder;
const SshSession = @import("ssh.zig").SshSession;
const ChecksumDb = @import("checksum_db.zig").ChecksumDb;
const Scanner = @import("scanner.zig").Scanner;
const FileEntry = @import("scanner.zig").FileEntry;
pub const Watcher = @import("watcher.zig").Watcher;
const checksum_db = @import("checksum_db.zig");
const ansi = @import("ansi.zig");

pub var ssh_mutex = std.Io.Mutex.init;

pub const FolderSync = struct {
    folder: *const Folder,
    remote_db: ChecksumDb,
    remote_db_path: []const u8,
    watcher: Watcher,
};

pub fn performInitialSync(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    config: *const Config,
    folder: *const Folder,
    ssh: *SshSession,
    remote_db: *ChecksumDb,
    remote_db_path: []const u8,
    printer: ansi.Printer,
) !bool {
    var scanner = Scanner.init(allocator, io, config, folder);
    defer scanner.deinit();
    try scanner.scanDirectory();
    if (config.verbose) std.debug.print("Found {} local files.\n", .{scanner.files.items.len});

    var changed_files = try scanner.getChangedFiles(remote_db);
    defer {
        for (changed_files.items) |entry| {
            allocator.free(entry.path);
        }
        changed_files.deinit(allocator);
    }

    if (changed_files.items.len == 0) {
        if (config.verbose) std.debug.print("Folder {s} is up to date!\n", .{folder.local_dir});
        return false;
    }

    std.debug.print("Uploading {} changed files for {s}...\n", .{ changed_files.items.len, folder.local_dir });

    // Parallel upload using thread pool
    const num_threads = @min(config.parallel_threads, changed_files.items.len);

    if (num_threads <= 1) {
        // Single-threaded mode
        for (changed_files.items, 1..) |entry, i| {
            if (config.dry_run) {
                std.debug.print("[{}/{}] Dry-run: Would sync: {s}\n", .{ i, changed_files.items.len, entry.path });
            } else {
                std.debug.print("[{}/{}] Syncing: {s}\n", .{ i, changed_files.items.len, entry.path });
                try syncFile(allocator, config, folder, ssh, entry.path);
                try remote_db.put(entry.path, entry.checksum, entry.mtime, entry.size);
                printer.printc(.yellow, "[{}/{}] Synced: {s}\n", .{ i, changed_files.items.len, entry.path });
            }
        }
    } else {
        // Multi-threaded mode
        var work_ctx = WorkContext{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .config = config,
            .folder = folder,
            .ssh = ssh,
            .remote_db = remote_db,
            .files = changed_files.items,
            .next_index = 0,
            .completed = 0,
            .total = changed_files.items.len,
            .mutex = std.Io.Mutex.init,
            .has_error = false,
            .printer = printer,
        };

        const threads = try allocator.alloc(std.Thread, num_threads);
        defer allocator.free(threads);

        for (threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, uploadWorker, .{&work_ctx});
        }

        for (threads) |thread| {
            thread.join();
        }

        if (work_ctx.has_error) {
            return error.UploadFailed;
        }
    }

    if (!folder.no_db and !config.dry_run) {
        // Prune database: re-populate with only current local files
        remote_db.clear();
        for (scanner.files.items) |entry| {
            try remote_db.put(entry.path, entry.checksum, entry.mtime, entry.size);
        }

        // Save updated database
        try ssh_mutex.lock(io);
        defer ssh_mutex.unlock(io);
        try saveDatabase(allocator, io, config, folder, remote_db, ssh, remote_db_path);
    }

    // Initial Cleanup if requested
    if (config.cleanup) {
        var local_paths = std.StringHashMap(void).init(allocator);
        defer local_paths.deinit();
        for (scanner.files.items) |entry| {
            try local_paths.put(entry.path, {});
        }
        try performCleanup(allocator, config, folder, ssh, &local_paths);
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

            // Skip .scpdb itself
            if (std.mem.eql(u8, rel_path, folder.scpdb)) continue;

            // Check if it matches include/exclude
            if (shouldSyncFile(rel_path, folder)) {
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

pub const WorkContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    config: *const Config,
    folder: *const Folder,
    ssh: *SshSession,
    remote_db: *ChecksumDb,
    files: []const FileEntry,
    next_index: usize,
    completed: usize,
    total: usize,
    mutex: std.Io.Mutex,
    has_error: bool,
    printer: ansi.Printer,
};

pub fn uploadWorker(ctx: *WorkContext) void {
    var local_ssh: ?SshSession = null;
    defer if (local_ssh) |*s| s.deinit();

    // In multi-threaded mode, each worker gets its own session for true parallelism
    local_ssh = SshSession.init(
        ctx.allocator,
        ctx.io,
        ctx.environ,
        ctx.config.host,
        ctx.config.username,
        ctx.config.password,
        ctx.config.key_path,
        ctx.config.passphrase,
        ctx.config.compress,
        ctx.config.file_mode,
        ctx.config.dir_mode,
        ctx.config.verbose,
    ) catch |err| {
        std.debug.print("Worker failed to connect: {s}\n", .{@errorName(err)});
        ctx.mutex.lock(ctx.io) catch {};
        ctx.has_error = true;
        ctx.mutex.unlock(ctx.io);
        return;
    };

    while (true) {
        // Get next file to upload
        ctx.mutex.lock(ctx.io) catch break;
        if (ctx.next_index >= ctx.files.len) {
            ctx.mutex.unlock(ctx.io);
            break;
        }
        const index = ctx.next_index;
        ctx.next_index += 1;
        ctx.mutex.unlock(ctx.io);

        const entry = ctx.files[index];

        if (ctx.config.dry_run) {
            std.debug.print("[{}/{}] Dry-run: Would sync: {s}\n", .{ index + 1, ctx.total, entry.path });
        } else {
            // Upload file (using local session, no global lock)
            syncFile(ctx.allocator, ctx.config, ctx.folder, &local_ssh.?, entry.path) catch |err| {
                std.debug.print("Upload failed for {s}: {s}\n", .{ entry.path, @errorName(err) });
                ctx.mutex.lock(ctx.io) catch {};
                ctx.has_error = true;
                ctx.mutex.unlock(ctx.io);
                continue;
            };
        }

        // Update progress AND database (thread-safe)
        ctx.mutex.lock(ctx.io) catch {};
        ctx.completed += 1;
        if (!ctx.config.dry_run) {
            ctx.remote_db.put(entry.path, entry.checksum, entry.mtime, entry.size) catch {};
        }
        const completed = ctx.completed;
        const total = ctx.total;
        ctx.mutex.unlock(ctx.io);

        ctx.printer.printc(.yellow, "[{}/{}] Synced: {s}\n", .{ completed, total, entry.path });
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

            if (event.kind == .created or event.kind == .modified) {
                if (!shouldSyncFile(event.path, fs.folder)) continue;

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

    if (fs.folder.no_db) {
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

        if (!fs.folder.no_db) {
            try fs.remote_db.put(rel_path, checksum, mtime, stat.size);
            try saveDatabase(allocator, io, config, fs.folder, &fs.remote_db, ssh, fs.remote_db_path);
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

pub fn shouldSyncFile(path: []const u8, folder: *const Folder) bool {
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

    const template_content = std.Io.Dir.cwd().readFileAlloc(io, version_from, allocator, @as(std.Io.Limit, @enumFromInt(1024 * 1024))) catch |err| {
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
) !void {
    if (folder.no_db) return;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try db.serialize(&aw.writer);

    const data = aw.writer.buffer[0..aw.writer.end];

    if (folder.local_db) {
        const full_path = if (std.fs.path.isAbsolute(folder.scpdb))
            try allocator.dupe(u8, folder.scpdb)
        else
            try std.fs.path.resolve(allocator, &[_][]const u8{ folder.local_dir, folder.scpdb });
        defer allocator.free(full_path);

        std.debug.print("[{s}] Saving database locally to {s}...\n", .{ folder.local_dir, full_path });
        std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(full_path) orelse ".") catch {};
        const file = try std.Io.Dir.cwd().createFile(io, full_path, .{});
        defer file.close(io);
        var write_buf: [4096]u8 = undefined;
        var file_writer = file.writer(io, &write_buf);
        try file_writer.interface.writeAll(data);
        try file_writer.interface.flush();
    } else {
        std.debug.print("[{s}] Uploading database to {s}...\n", .{ folder.local_dir, db_path });
        try ssh.uploadBuffer(data, db_path, config.simple_log);
    }
}
