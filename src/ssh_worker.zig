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
    config: *const Config,
    folder: *const Folder,
    ssh: *SshSession,
    remote_db: *ChecksumDb,
    remote_db_path: []const u8,
) !void {
    std.debug.print("Scanning local directory: {s}\n", .{folder.local_dir});
    var scanner = Scanner.init(allocator, io, config, folder);
    defer scanner.deinit();
    try scanner.scanDirectory();
    std.debug.print("Found {} local files.\n", .{scanner.files.items.len});

    var changed_files = try scanner.getChangedFiles(remote_db);
    defer {
        for (changed_files.items) |entry| {
            allocator.free(entry.path);
        }
        changed_files.deinit(allocator);
    }

    if (changed_files.items.len == 0) {
        std.debug.print("Folder {s} is up to date!\n", .{folder.local_dir});
        return;
    }

    std.debug.print("Uploading {} changed files for {s}...\n", .{ changed_files.items.len, folder.local_dir });

    // Parallel upload using thread pool
    const num_threads = @min(config.parallel_threads, changed_files.items.len);

    if (num_threads <= 1) {
        // Single-threaded mode
        for (changed_files.items, 1..) |entry, i| {
            std.debug.print("[{}/{}] Syncing: {s}\n", .{ i, changed_files.items.len, entry.path });
            try syncFile(allocator, config, folder, ssh, entry.path);
            try remote_db.put(entry.path, entry.checksum, entry.mtime);
            std.debug.print("[{}/{}] Synced: {s}\n", .{ i, changed_files.items.len, entry.path });
        }
    } else {
        // Multi-threaded mode
        var work_ctx = WorkContext{
            .allocator = allocator,
            .io = io,
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

    // Prune database: re-populate with only current local files
    remote_db.clear();
    for (scanner.files.items) |entry| {
        try remote_db.put(entry.path, entry.checksum, entry.mtime);
    }

    // Save updated database
    try ssh_mutex.lock(io);
    defer ssh_mutex.unlock(io);
    try saveDatabase(allocator, io, config, folder, remote_db, ssh, remote_db_path);

    // Initial Cleanup if requested
    if (config.cleanup) {
        var local_paths = std.StringHashMap(void).init(allocator);
        defer local_paths.deinit();
        for (scanner.files.items) |entry| {
            try local_paths.put(entry.path, {});
        }
        try performCleanup(allocator, folder, ssh, &local_paths);
    }

    if (config.exec_cmd) |cmd| {
        std.debug.print("Executing remote command after initial sync: {s}\n", .{cmd});
        ssh.exec(cmd) catch |err| {
            std.debug.print("Warning: Failed to execute remote command: {s}\n", .{@errorName(err)});
        };
    }

    try performSyncTrigger(allocator, config, folder, ssh);

    std.debug.print("Initial sync complete for {s}!\n", .{folder.local_dir});
}

pub fn performCleanup(
    allocator: std.mem.Allocator,
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
                    std.debug.print("Cleanup: Removing remote file {s}\n", .{remote_full_path});
                    try ssh.removeRemoteFile(remote_full_path);
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
};

pub fn uploadWorker(ctx: *WorkContext) void {
    var local_ssh: ?SshSession = null;
    defer if (local_ssh) |*s| s.deinit();

    // In multi-threaded mode, each worker gets its own session for true parallelism
    local_ssh = SshSession.init(
        ctx.allocator,
        ctx.io,
        ctx.config.host,
        ctx.config.username,
        ctx.config.password,
        ctx.config.key_path,
        ctx.config.passphrase,
        ctx.config.compress,
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

        std.debug.print("[{}/{}] Syncing: {s}\n", .{ index + 1, ctx.total, entry.path });

        // Upload file (using local session, no global lock)
        syncFile(ctx.allocator, ctx.config, ctx.folder, &local_ssh.?, entry.path) catch |err| {
            std.debug.print("Upload failed for {s}: {s}\n", .{ entry.path, @errorName(err) });
            ctx.mutex.lock(ctx.io) catch {};
            ctx.has_error = true;
            ctx.mutex.unlock(ctx.io);
            continue;
        };

        // Update progress AND database (thread-safe)
        ctx.mutex.lock(ctx.io) catch {};
        ctx.completed += 1;
        ctx.remote_db.put(entry.path, entry.checksum, entry.mtime) catch {};
        const completed = ctx.completed;
        const total = ctx.total;
        ctx.mutex.unlock(ctx.io);

        std.debug.print("[{}/{}] Synced: {s}\n", .{ completed, total, entry.path });
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

            processReadySync(allocator, io, config, ssh, fs, rel_path) catch |err| {
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
) !void {
    const local_path = try std.fs.path.join(allocator, &[_][]const u8{ fs.folder.local_dir, rel_path });
    defer allocator.free(local_path);

    // Check if file still exists
    std.Io.Dir.cwd().access(io, local_path, .{}) catch return;

    // Check if actually a file and get mtime
    const stat = std.Io.Dir.cwd().statFile(io, local_path, .{}) catch return;
    if (stat.kind == .directory) return;
    const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));

    const is_text = checksum_db.isTextFile(rel_path, config.text_extensions);
    const checksum = try checksum_db.calculateFileChecksum(allocator, io, local_path, is_text);

    // Check if actually changed
    if (fs.remote_db.get(rel_path)) |old_entry| {
        if (old_entry.hash == checksum) {
            std.debug.print("[{s}] No content change: {s}\n", .{ fs.folder.local_dir, rel_path });
            return;
        }
    }

    std.debug.print("[{s}] Uploading: {s}\n", .{ fs.folder.local_dir, rel_path });

    try ssh_mutex.lock(io);
    defer ssh_mutex.unlock(io);

    try syncFile(allocator, config, fs.folder, ssh, rel_path);

    try fs.remote_db.put(rel_path, checksum, mtime);
    try saveDatabase(allocator, io, config, fs.folder, &fs.remote_db, ssh, fs.remote_db_path);

    if (config.exec_cmd) |cmd| {
        std.debug.print("[{s}] Executing remote command: {s}\n", .{ fs.folder.local_dir, cmd });
        ssh.exec(cmd) catch |err| {
            std.debug.print("Warning: Failed to execute remote command: {s}\n", .{@errorName(err)});
        };
    }

    try performSyncTrigger(allocator, config, fs.folder, ssh);

    std.debug.print("[{s}] Synced: {s}\n\n", .{ fs.folder.local_dir, rel_path });
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
        std.debug.print("[{s}] Copying trigger file: {s} -> {s}\n", .{ folder.local_dir, trigger_from, trigger_to });
        ssh.uploadFile(trigger_from, trigger_to, config.simple_log) catch |err| {
            std.debug.print("Warning: Failed to copy trigger file: {s}\n", .{@errorName(err)});
        };
    } else {
        std.debug.print("[{s}] Writing empty trigger file: {s}\n", .{ folder.local_dir, trigger_to });
        ssh.uploadBuffer(&[_]u8{}, trigger_to, config.simple_log) catch |err| {
            std.debug.print("Warning: Failed to write empty trigger file: {s}\n", .{@errorName(err)});
        };
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
