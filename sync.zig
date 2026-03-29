// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const Config = @import("src/config.zig").Config;
const SshSession = @import("src/ssh.zig").SshSession;
const ChecksumDb = @import("src/checksum_db.zig").ChecksumDb;
const Scanner = @import("src/scanner.zig").Scanner;
const ssh_worker = @import("src/ssh_worker.zig");
const local_worker = @import("src/local_worker.zig");

pub fn main() !void {
    try SshSession.libInit();
    defer SshSession.libExit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();

    // Parse configuration
    var config = Config.parseArgs(parse_arena.allocator()) catch |err| {
        return err;
    };

    // Check for standalone create mode
    if (config.create_folder) |create_path| {
        try handleCreateDb(allocator, &config, create_path);
        return;
    }

    if (config.folders.len == 0 and config.local_copy_workers.len == 0 and config.get_file == null and config.put_file == null) {
        std.debug.print("Error: No sync folders or local copy workers configured.\n", .{});
        return;
    }

    // Initialize local copy workers (they don't need SSH)
    var local_workers = try allocator.alloc(local_worker.LocalCopyWorker, config.local_copy_workers.len);
    defer {
        for (local_workers) |*lw| lw.deinit();
        allocator.free(local_workers);
    }

    for (config.local_copy_workers, 0..) |*lw_config, i| {
        local_workers[i] = try local_worker.LocalCopyWorker.init(allocator, &config, lw_config);
        try local_workers[i].performInitialSync();
    }

    if (config.folders.len == 0) {
        if (config.get_file != null or config.put_file != null) {
            // continue to SSH part if get/put is requested
        } else if (config.local_copy_workers.len > 0) {
            // Only local copy workers, start them and wait
            std.debug.print("\nStarting local copy workers...\n", .{});
            var threads = try allocator.alloc(std.Thread, local_workers.len);
            defer allocator.free(threads);

            for (local_workers, 0..) |*lw, i| {
                threads[i] = try std.Thread.spawn(.{}, local_worker.watchLocalCopyThread, .{lw});
            }

            for (threads) |thread| thread.join();
            return;
        }
    }

    std.debug.print("Connecting to {s}@{s}...\n", .{ config.username, config.host });

    // Connect to SSH
    var ssh = SshSession.init(allocator, config.host, config.username, config.password, config.key_path, config.passphrase, config.compress) catch |err| {
        std.debug.print("SSH error: {s}\n", .{@errorName(err)});
        return err;
    };
    defer ssh.deinit();

    std.debug.print("Connected successfully!\n", .{});

    if (config.get_file) |gf| {
        const remote_path = gf[0];
        const local_path = gf[1];
        std.debug.print("Downloading {s} to {s}...\n", .{ remote_path, local_path });
        try ssh.downloadFile(remote_path, local_path);
        std.debug.print("Downloaded successfully.\n", .{});
        return;
    }

    if (config.put_file) |pf| {
        const local_path = pf[0];
        const remote_path = pf[1];

        // Ensure remote directory exists
        if (std.mem.lastIndexOfScalar(u8, remote_path, '/')) |last_slash| {
            const remote_dir = remote_path[0..last_slash];
            ssh.createRemoteDir(remote_dir) catch |err| {
                std.debug.print("Warning: Failed to create remote dir {s}: {s}\n", .{ remote_dir, @errorName(err) });
            };
        }

        std.debug.print("Uploading {s} to {s}...\n", .{ local_path, remote_path });
        try ssh.uploadFile(local_path, remote_path, config.simple_log);
        std.debug.print("Uploaded successfully.\n", .{});
        return;
    }

    // Initialize all folders
    var folder_syncs = try allocator.alloc(ssh_worker.FolderSync, config.folders.len);
    defer {
        for (folder_syncs) |*fs| {
            fs.remote_db.deinit();
            allocator.free(fs.remote_db_path);
            fs.watcher.deinit();
        }
        allocator.free(folder_syncs);
    }

    for (config.folders, 0..) |*folder, i| {
        std.debug.print("\n=== Initializing folder: {s} ===\n", .{folder.local_dir});

        // Setup DB path and load database
        const is_absolute_db = std.fs.path.isAbsolute(folder.scpdb);
        var db_path: []const u8 = undefined;
        var remote_db = ChecksumDb.init(allocator);

        if (folder.local_db) {
            db_path = if (is_absolute_db)
                try allocator.dupe(u8, folder.scpdb)
            else
                try std.fs.path.resolve(allocator, &[_][]const u8{ folder.local_dir, folder.scpdb });

            if (std.fs.cwd().openFile(db_path, .{})) |file| {
                defer file.close();
                const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
                defer allocator.free(content);
                remote_db.deinit();
                remote_db = try ChecksumDb.deserialize(allocator, content);
                std.debug.print("Loaded local database: {s} ({} entries)\n", .{ db_path, remote_db.entries.count() });
            } else |_| {
                std.debug.print("No local database found at {s}, starting fresh.\n", .{db_path});
            }
        } else {
            const remote_db_path_win = try std.fs.path.join(allocator, &[_][]const u8{ folder.remote_dir, folder.scpdb });
            defer allocator.free(remote_db_path_win);
            const mutable_db_path = try allocator.dupe(u8, remote_db_path_win);
            std.mem.replaceScalar(u8, mutable_db_path, '\\', '/');
            db_path = mutable_db_path;

            std.debug.print("Downloading remote checksum database from {s}...\n", .{db_path});
            const random_id = std.crypto.random.int(u64);
            var tmp_name: [64]u8 = undefined;
            const tmp_path = try std.fmt.bufPrint(&tmp_name, ".scpdb.{x}.tmp", .{random_id});

            ssh_worker.ssh_mutex.lock();
            if (ssh.downloadFile(db_path, tmp_path)) |_| {
                ssh_worker.ssh_mutex.unlock();
                if (std.fs.cwd().openFile(tmp_path, .{})) |file| {
                    defer file.close();
                    defer std.fs.cwd().deleteFile(tmp_path) catch {};
                    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
                    defer allocator.free(content);
                    remote_db.deinit();
                    remote_db = try ChecksumDb.deserialize(allocator, content);
                    std.debug.print("Loaded remote database with {} entries.\n", .{remote_db.entries.count()});
                } else |_| {}
            } else |err| {
                ssh_worker.ssh_mutex.unlock();
                if (err == error.RemoteFileOpenFailed) {
                    std.debug.print("No remote database found, starting fresh sync.\n", .{});
                } else {
                    remote_db.deinit();
                    allocator.free(db_path);
                    return err;
                }
            }
        }

        // Perform initial sync with timing
        const sync_start = std.time.milliTimestamp();
        try ssh_worker.performInitialSync(allocator, &config, folder, &ssh, &remote_db, db_path);
        const sync_end = std.time.milliTimestamp();
        const sync_duration = @as(f64, @floatFromInt(sync_end - sync_start)) / 1000.0;
        std.debug.print("Initial sync completed in {d:.2} seconds.\n\n", .{sync_duration});

        // Initialize watcher
        const watcher_inst = try ssh_worker.Watcher.init(allocator, folder.local_dir);

        folder_syncs[i] = .{
            .folder = folder,
            .remote_db = remote_db,
            .remote_db_path = db_path,
            .watcher = watcher_inst,
        };
    }

    // Start watching all folders
    std.debug.print("\nStarting file watchers for {} folders...\n", .{folder_syncs.len + local_workers.len});
    std.debug.print("Press Ctrl+C to stop.\n\n", .{});

    // For simplicity, we create a thread for each folder watcher
    var threads = try allocator.alloc(std.Thread, folder_syncs.len + local_workers.len);
    defer allocator.free(threads);

    for (folder_syncs, 0..) |*fs, i| {
        threads[i] = try std.Thread.spawn(.{}, ssh_worker.watchFolderThread, .{ allocator, &config, &ssh, fs });
    }

    for (local_workers, 0..) |*lw, i| {
        threads[folder_syncs.len + i] = try std.Thread.spawn(.{}, local_worker.watchLocalCopyThread, .{lw});
    }

    // Join threads
    for (threads) |thread| {
        thread.join();
    }
}

fn handleCreateDb(allocator: std.mem.Allocator, config: *const Config, folder_path: []const u8) !void {
    std.debug.print("Creating .scpdb for: {s}\n", .{folder_path});

    var temp_folder = @import("src/config.zig").Folder{
        .scpdb = ".scpdb",
        .local_db = true,
        .local_dir = folder_path, // already arena-owned via config
        .remote_dir = ".",
        .include_patterns = config.create_includes,
        .exclude_patterns = config.create_excludes,
    };

    // Scan directory
    var scanner = Scanner.init(allocator, config, &temp_folder);
    defer scanner.deinit();

    try scanner.scanDirectory();
    std.debug.print("Found {} files matching patterns.\n", .{scanner.files.items.len});

    // Create database
    var db = ChecksumDb.init(allocator);
    defer db.deinit();

    for (scanner.files.items) |entry| {
        try db.put(entry.path, entry.checksum, entry.mtime);
    }

    // Save database
    const db_path = try std.fs.path.join(allocator, &[_][]const u8{ folder_path, ".scpdb" });
    defer allocator.free(db_path);

    const file = try std.fs.cwd().createFile(db_path, .{});
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.Writer.init(file, &buffer);
    try db.serialize(&writer.interface);
    try writer.interface.flush();

    std.debug.print("Successfully created {s}\n", .{db_path});
}
