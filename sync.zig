// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const Config = @import("src/config.zig").Config;
const SshSession = @import("src/ssh.zig").SshSession;
const ChecksumDb = @import("src/checksum_db.zig").ChecksumDb;
const Scanner = @import("src/scanner.zig").Scanner;
const ssh_worker = @import("src/ssh_worker.zig");
const local_worker = @import("src/local_worker.zig");
const ansi = @import("src/ansi.zig");
const db_loc = @import("src/db_path.zig");

/// Upper bound for reading a checksum database (local or downloaded).
const max_db_size: u64 = 10 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    try SshSession.libInit();
    defer SshSession.libExit();

    const allocator = init.gpa;

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();

    const args = try init.minimal.args.toSlice(parse_arena.allocator());
    // skip executable name
    const app_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    // Parse configuration
    var config = Config.parseArgs(parse_arena.allocator(), init, app_args) catch |err| {
        switch (err) {
            error.MissingArguments => {
                std.debug.print("Error: -c/--config is required for sync mode.\n", .{});
                std.process.exit(1);
            },
            error.MissingArgValue => {
                std.debug.print("Error: Missing argument value.\n", .{});
                std.process.exit(1);
            },
            error.UnknownArgument => {
                std.debug.print("Error: Unknown argument.\n", .{});
                std.process.exit(1);
            },
            // The detailed message was already printed while expanding the value.
            error.UndefinedConfigVariable,
            error.EmptyConfigVariable,
            error.InvalidVariableName,
            error.UnclosedVariableBrace,
            => std.process.exit(1),
            else => {},
        }
        return err;
    };

    // Check for standalone create mode
    if (config.create_folder) |create_path| {
        try handleCreateDb(allocator, init.io, &config, create_path);
        return;
    }

    if (config.folders.len == 0 and config.local_copy_workers.len == 0 and config.get_file == null and config.put_file == null) {
        std.debug.print("Error: No sync folders or local copy workers configured.\n", .{});
        return;
    }

    // Every folder must keep its own database. Two folders resolving to the
    // same file would overwrite each other's entries, so each run would see an
    // empty database and re-upload that folder in full, forever.
    validateDatabaseTargets(allocator, &config) catch |err| switch (err) {
        error.DatabaseLocationConflict => std.process.exit(1),
        else => return err,
    };

    if (config.watch_backend == .fsmeta and
        (config.folders.len > 0 or config.local_copy_workers.len > 0))
    {
        std.debug.print(
            "Error: the fs-meta Unix-socket watcher backend is not implemented yet (socket: {s}).\n" ++
                "Use watch_backend=nightwatch for now.\n",
            .{config.fsmeta_socket orelse "<unset>"},
        );
        std.process.exit(1);
    }

    // Initialize local copy workers (they don't need SSH)
    var local_workers = try allocator.alloc(local_worker.LocalCopyWorker, config.local_copy_workers.len);
    defer {
        for (local_workers) |*lw| lw.deinit();
        allocator.free(local_workers);
    }

    for (config.local_copy_workers, 0..) |*lw_config, i| {
        local_workers[i] = try local_worker.LocalCopyWorker.init(allocator, init.io, &config, lw_config);
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

    const printer: ansi.Printer = .{ .color_enabled = config.color };
    std.debug.print("Connecting to {s}@{s}...\n", .{ config.username, config.host });

    // Connect to SSH
    var ssh = try SshSession.init(allocator, init.io, init.minimal.environ, config.host, config.username, config.password, config.key_path, config.passphrase, config.compress, config.file_mode, config.dir_mode, config.verbose);
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
    var folder_syncs_count: usize = 0;
    defer {
        for (folder_syncs[0..folder_syncs_count]) |*fs| {
            fs.remote_db.deinit();
            if (fs.remote_db_path.len > 0) allocator.free(fs.remote_db_path);
            if (fs.db_rels.len > 0) db_loc.freeRelPaths(allocator, fs.db_rels);
            fs.watcher.deinit();
        }
        allocator.free(folder_syncs);
    }

    var any_changes = false;
    for (config.folders) |*folder| {
        std.debug.print("\n=== Initializing folder: {s} ===\n", .{folder.local_dir});

        // A missing local directory is created instead of aborting the whole
        // run; build output folders (target/classes, dist, ...) regularly do
        // not exist yet on a fresh checkout.
        if (!ensureLocalDir(init.io, folder.local_dir)) continue;

        // Setup DB path and load database. `db_loc.resolve` is the single
        // source of truth: the same value is used to save the database later.
        var db_path: []const u8 = ""; // empty default (literal, no allocation)
        var remote_db = ChecksumDb.init(allocator);

        if (!folder.no_db) {
            const resolved = try db_loc.resolve(allocator, folder);
            db_path = resolved.path;

            if (resolved.kind == .local) {
                if (std.Io.Dir.cwd().readFileAlloc(init.io, db_path, allocator, std.Io.Limit.limited(max_db_size))) |content| {
                    defer allocator.free(content);
                    remote_db.deinit();
                    remote_db = try ChecksumDb.deserialize(allocator, content);
                    std.debug.print("Loaded local database: {s} ({} entries)\n", .{ db_path, remote_db.entries.count() });
                    if (remote_db.entries.count() == 0) {
                        std.debug.print("Database {s} is empty; treating the folder as not synced.\n", .{db_path});
                    }
                } else |err| {
                    if (err == error.FileNotFound) {
                        std.debug.print("No local database found at {s}, starting fresh.\n", .{db_path});
                    } else {
                        std.debug.print("Warning: cannot read local database {s} ({s}); starting fresh.\n", .{ db_path, @errorName(err) });
                    }
                }
            } else {
                if (config.verbose) std.debug.print("Downloading remote checksum database from {s}...\n", .{db_path});
                var random_id: u64 = undefined;
                init.io.random(std.mem.asBytes(&random_id));
                var tmp_name: [64]u8 = undefined;
                const tmp_path = try std.fmt.bufPrint(&tmp_name, ".scpdb.{x}.tmp", .{random_id});

                ssh_worker.ssh_mutex.lock(init.io) catch {};
                if (ssh.downloadFile(db_path, tmp_path)) |_| {
                    ssh_worker.ssh_mutex.unlock(init.io);
                    if (std.Io.Dir.cwd().readFileAlloc(init.io, tmp_path, allocator, std.Io.Limit.limited(max_db_size))) |content| {
                        defer std.Io.Dir.cwd().deleteFile(init.io, tmp_path) catch {};
                        defer allocator.free(content);
                        remote_db.deinit();
                        remote_db = try ChecksumDb.deserialize(allocator, content);
                        if (config.verbose) std.debug.print("Loaded remote database with {} entries.\n", .{remote_db.entries.count()});
                        if (remote_db.entries.count() == 0) {
                            std.debug.print("Database {s} is empty; treating the folder as not synced.\n", .{db_path});
                        }
                    } else |err| {
                        std.debug.print("Warning: cannot read downloaded database {s} ({s}); starting fresh.\n", .{ db_path, @errorName(err) });
                    }
                } else |err| {
                    ssh_worker.ssh_mutex.unlock(init.io);
                    if (err == error.RemoteFileOpenFailed) {
                        std.debug.print("No database found on the server at {s}; syncing this folder in full once.\n", .{db_path});
                    } else {
                        remote_db.deinit();
                        if (db_path.len > 0) allocator.free(db_path);
                        return err;
                    }
                }
            }
        } else {
            if (config.verbose) std.debug.print("Skipping database (no_db mode enabled).\n", .{});
        }

        // Perform initial sync with timing
        const t0 = std.Io.Timestamp.now(init.io, .boot);
        if (try ssh_worker.performInitialSync(allocator, init.io, init.minimal.environ, &config, folder, &ssh, &remote_db, db_path, printer)) {
            any_changes = true;
        }
        const elapsed_ns = t0.durationTo(std.Io.Timestamp.now(init.io, .boot)).nanoseconds;
        const sync_duration = @as(f64, @floatFromInt(@as(i64, @intCast(elapsed_ns)))) / @as(f64, @floatFromInt(std.time.ns_per_s));
        std.debug.print("Initial sync completed in {d:.2} seconds for {s}.\n\n", .{ sync_duration, folder.local_dir });

        // Initialize watcher
        var watcher_inst = try ssh_worker.Watcher.init(allocator, init.io, folder.local_dir, .{
            .backend = config.watch_backend,
            .fsmeta_socket = config.fsmeta_socket,
        });
        if (config.verbose) {
            std.debug.print("[{s}] Watch backend {s}: {d} registration(s)\n", .{
                folder.local_dir,
                @tagName(config.watch_backend),
                watcher_inst.watchCount(),
            });
        }

        folder_syncs[folder_syncs_count] = .{
            .folder = folder,
            .remote_db = remote_db,
            .remote_db_path = db_path,
            .db_rels = db_loc.relPathsInTree(allocator, init.io, config.folders, folder) catch &[_][]const u8{},
            .watcher = watcher_inst,
        };
        folder_syncs_count += 1;
    }

    if (any_changes) {
        try ssh_worker.performVersionFileUpload(allocator, init.io, &config, null, &ssh);
    }

    if (config.watch) {
        const watcher_count = folder_syncs_count + local_workers.len;
        // Start watching all folders
        std.debug.print("\nStarting file watchers for {} folders...\n", .{watcher_count});
        std.debug.print("Press Ctrl+C to stop.\n\n", .{});

        // For simplicity, we create a thread for each folder watcher
        var threads = try allocator.alloc(std.Thread, watcher_count);
        defer allocator.free(threads);

        for (folder_syncs[0..folder_syncs_count], 0..) |*fs, i| {
            threads[i] = try std.Thread.spawn(.{}, ssh_worker.watchFolderThread, .{ allocator, init.io, &config, &ssh, fs, printer });
        }

        for (local_workers, 0..) |*lw, i| {
            threads[folder_syncs_count + i] = try std.Thread.spawn(.{}, local_worker.watchLocalCopyThread, .{lw});
        }

        // Join threads
        for (threads) |thread| {
            thread.join();
        }
    } else {
        std.debug.print("\nSync completed. Watch mode not enabled (-w to enable).\n", .{});
    }
}

/// Make sure a folder's local directory exists. A missing directory is created
/// (build output folders often do not exist yet); a path that cannot be used is
/// reported and the folder is skipped instead of aborting the whole run.
fn ensureLocalDir(io: std.Io, dir: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, dir, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("[{s}] Local directory does not exist; creating it.\n", .{dir});
            std.Io.Dir.cwd().createDirPath(io, dir) catch |create_err| {
                std.debug.print(
                    "Warning: cannot create local_dir '{s}' ({s}); skipping this folder.\n",
                    .{ dir, @errorName(create_err) },
                );
                return false;
            };
            return true;
        },
        else => {
            std.debug.print(
                "Warning: local_dir '{s}' is not accessible ({s}); skipping this folder.\n",
                .{ dir, @errorName(err) },
            );
            return false;
        },
    };
    if (stat.kind != .directory) {
        std.debug.print("Warning: local_dir '{s}' is not a directory; skipping this folder.\n", .{dir});
        return false;
    }
    return true;
}

/// Reject configurations where two folders would share one checksum database.
/// Each folder must keep its own database: a shared file makes the folders
/// overwrite each other's entries, so every run re-uploads both in full.
fn validateDatabaseTargets(allocator: std.mem.Allocator, config: *const Config) !void {
    if (config.folders.len < 2) return;

    var seen = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        seen.deinit();
    }

    var conflicts: usize = 0;
    for (config.folders) |*folder| {
        if (folder.no_db) continue;

        const resolved = db_loc.resolve(allocator, folder) catch continue;
        const key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{
            if (resolved.kind == .local) "local" else "remote",
            resolved.path,
        });

        if (seen.get(key)) |first| {
            std.debug.print(
                "Config error: folders '{s}' and '{s}' would share one checksum database.\n" ++
                    "  Database location: {s}\n" ++
                    "  Each folder must keep its own .scpdb, otherwise they overwrite each\n" ++
                    "  other's entries and every run re-uploads every file. Give each folder a\n" ++
                    "  distinct 'scpdb' value, for example:\n" ++
                    "    [folder]\n" ++
                    "    local_dir = {s}\n" ++
                    "    scpdb = .scpdb.<unique-name>\n",
                .{ first, folder.local_dir, resolved.path, folder.local_dir },
            );
            allocator.free(resolved.path);
            allocator.free(key);
            conflicts += 1;
            continue;
        }

        allocator.free(resolved.path);
        try seen.put(key, folder.local_dir);
    }

    if (conflicts > 0) return error.DatabaseLocationConflict;
}

fn handleCreateDb(allocator: std.mem.Allocator, io: anytype, config: *const Config, folder_path: []const u8) !void {
    std.debug.print("Creating .scpdb for: {s}\n", .{folder_path});

    var temp_folder = @import("src/config.zig").Folder{
        .scpdb = ".scpdb",
        .local_db = true,
        .local_dir = folder_path, // already arena-owned via config
        .remote_dir = ".",
        .include_patterns = config.create_includes,
        .exclude_patterns = config.create_excludes,
        .trigger_from = null,
        .trigger_to = null,
        .version_from = null,
        .version_to = null,
        .version_name = null,
    };

    // Scan directory
    var scanner = Scanner.init(allocator, io, config, &temp_folder);
    defer scanner.deinit();

    try scanner.scanDirectory();
    std.debug.print("Found {} files matching patterns.\n", .{scanner.files.items.len});

    // Create database
    var db = ChecksumDb.init(allocator);
    defer db.deinit();

    for (scanner.files.items) |entry| {
        try db.put(entry.path, entry.checksum, entry.mtime, entry.size);
    }

    // Save database
    const db_path = try std.fs.path.join(allocator, &[_][]const u8{ folder_path, ".scpdb" });
    defer allocator.free(db_path);

    const file = try std.Io.Dir.cwd().createFile(io, db_path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try db.serialize(&writer.interface);
    try writer.interface.flush();

    std.debug.print("Successfully created {s}\n", .{db_path});
}
