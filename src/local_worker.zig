// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const Config = @import("config.zig").Config;
const LocalSource = @import("config.zig").LocalSource;
const LocalCopyWorkerConfig = @import("config.zig").LocalCopyWorkerConfig;
pub const Watcher = @import("watcher.zig").Watcher;
const Scanner = @import("scanner.zig").Scanner;
const ChecksumDb = @import("checksum_db.zig").ChecksumDb;
const checksum_utils = @import("checksum_db.zig");
const ANSI_YELLOW = "\x1b[33m";
const ANSI_RESET = "\x1b[0m";

pub const LocalSourceSync = struct {
    source: *const LocalSource,
    watcher: Watcher,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: *const LocalSource) !LocalSourceSync {
        return .{
            .source = source,
            .watcher = try Watcher.init(allocator, source.local_dir),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LocalSourceSync) void {
        self.watcher.deinit();
    }
};

pub const LocalCopyWorker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    lw_config: *const LocalCopyWorkerConfig,
    source_syncs: []LocalSourceSync,
    checksum_db: ChecksumDb,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: *const Config, lw_config: *const LocalCopyWorkerConfig) !LocalCopyWorker {
        var sources = try allocator.alloc(LocalSourceSync, lw_config.sources.len);
        errdefer allocator.free(sources);

        for (lw_config.sources, 0..) |*source, i| {
            sources[i] = try LocalSourceSync.init(allocator, source);
        }

        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .lw_config = lw_config,
            .source_syncs = sources,
            .checksum_db = ChecksumDb.init(allocator),
        };
    }

    pub fn deinit(self: *LocalCopyWorker) void {
        self.checksum_db.deinit();
        for (self.source_syncs) |*ss| ss.deinit();
        self.allocator.free(self.source_syncs);
    }

    pub fn performInitialSync(self: *LocalCopyWorker) !void {
        std.debug.print("LocalCopyWorker: Initial sync to {s}\n", .{self.lw_config.dest_dir});

        // Ensure destination exists
        try std.Io.Dir.cwd().createDirPath(self.io, self.lw_config.dest_dir);

        for (self.lw_config.sources) |*source| {
            std.debug.print("  Source: {s}\n", .{source.local_dir});

            var iter_dir = try std.Io.Dir.cwd().openDir(self.io, source.local_dir, .{ .iterate = true });
            defer iter_dir.close(self.io);

            var walker = try iter_dir.walk(self.allocator);
            defer walker.deinit();

            while (try walker.next(self.io)) |entry| {
                if (entry.kind != .file) continue;

                if (self.shouldCopyFile(entry.path, source)) {
                    const full_source = try std.fs.path.join(self.allocator, &[_][]const u8{ source.local_dir, entry.path });
                    defer self.allocator.free(full_source);

                    const is_text = checksum_utils.isTextFile(entry.path, self.config.text_extensions);
                    const hash = try checksum_utils.calculateFileChecksum(self.allocator, self.io, full_source, is_text);

                    const stat = try std.Io.Dir.cwd().statFile(self.io, full_source, .{});
                    const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));

                    const full_dest = try std.fs.path.join(self.allocator, &[_][]const u8{ self.lw_config.dest_dir, entry.path });
                    defer self.allocator.free(full_dest);

                    var skip = false;
                    if (self.checksum_db.get(entry.path)) |existing| {
                        if (existing.hash == hash) skip = true;
                    }

                    if (!skip) {
                        // Check if file already exists in destination and has same hash
                        if (std.Io.Dir.cwd().statFile(self.io, full_dest, .{})) |dest_stat| {
                            if (dest_stat.size == stat.size) {
                                const dest_hash = checksum_utils.calculateFileChecksum(self.allocator, self.io, full_dest, is_text) catch 0;
                                if (dest_hash == hash) skip = true;
                            }
                        } else |_| {}
                    }

                    if (!skip) {
                        try self.copyFile(source.local_dir, entry.path);
                    }
                    try self.checksum_db.put(entry.path, hash, mtime);
                }
            }
        }
    }

    pub fn shouldCopyFile(self: *LocalCopyWorker, rel_path: []const u8, source: *const LocalSource) bool {
        _ = self;
        for (source.exclude_patterns) |pattern| {
            if (Scanner.matchPattern(rel_path, pattern)) return false;
        }
        if (source.include_patterns.len > 0) {
            for (source.include_patterns) |pattern| {
                if (Scanner.matchPattern(rel_path, pattern)) return true;
            }
            return false;
        }
        return true;
    }

    pub fn copyFile(self: *LocalCopyWorker, source_dir: []const u8, rel_path: []const u8) !void {
        const full_source = try std.fs.path.join(self.allocator, &[_][]const u8{ source_dir, rel_path });
        defer self.allocator.free(full_source);

        const full_dest = try std.fs.path.join(self.allocator, &[_][]const u8{ self.lw_config.dest_dir, rel_path });
        defer self.allocator.free(full_dest);

        // Ensure dest parent dir exists
        if (std.fs.path.dirname(full_dest)) |parent| {
            try std.Io.Dir.cwd().createDirPath(self.io, parent);
        }

        // Copy file
        try std.Io.Dir.cwd().copyFile(full_source, std.Io.Dir.cwd(), full_dest, self.io, .{});
        if (self.config.color) {
            std.debug.print(ANSI_YELLOW ++ "  Copied: {s}" ++ ANSI_RESET ++ "\n", .{rel_path});
        } else {
            std.debug.print("  Copied: {s}\n", .{rel_path});
        }
    }
};

pub fn watchLocalCopyThread(lw: *LocalCopyWorker) void {
    const allocator = lw.allocator;
    const config = lw.config;

    // We need to track pending syncs per source
    var pending_syncs = std.StringHashMap(i64).init(allocator);
    defer {
        var it = pending_syncs.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        pending_syncs.deinit();
    }

    var ready_paths = std.ArrayList([]const u8).empty;
    defer ready_paths.deinit(allocator);

    while (true) {
        // Poll all watchers
        for (lw.source_syncs) |*ss| {
            ss.watcher.wait(10) catch {};

            while (true) {
                const event = ss.watcher.nextEvent() catch |err| {
                    std.debug.print("LocalWatcher error in {s}: {}\n", .{ ss.source.local_dir, err });
                    break;
                } orelse break;

                defer allocator.free(event.path);

                if (event.kind == .created or event.kind == .modified) {
                    if (!lw.shouldCopyFile(event.path, ss.source)) continue;

                    const target_time = @as(i64, @intCast(@divTrunc(std.Io.Timestamp.now(lw.io, .real).nanoseconds, std.time.ns_per_ms))) + @as(i64, @intCast(config.watch_delay_ms));

                    // Store both source_dir and rel_path to know where it came from
                    const combined_key = std.fs.path.join(allocator, &[_][]const u8{ ss.source.local_dir, event.path }) catch continue;

                    if (pending_syncs.getEntry(combined_key)) |entry| {
                        entry.value_ptr.* = target_time;
                        allocator.free(combined_key);
                    } else {
                        pending_syncs.put(combined_key, target_time) catch {
                            allocator.free(combined_key);
                        };
                    }
                }
            }
        }

        // Check for ready syncs
        const now = @as(i64, @intCast(@divTrunc(std.Io.Timestamp.now(lw.io, .real).nanoseconds, std.time.ns_per_ms)));
        var it = pending_syncs.iterator();
        while (it.next()) |entry| {
            if (now >= entry.value_ptr.*) {
                ready_paths.append(allocator, entry.key_ptr.*) catch {};
            }
        }

        // Process ready syncs
        for (ready_paths.items) |combined_path| {
            _ = pending_syncs.remove(combined_path);

            // Find which source this belongs to
            for (lw.source_syncs) |*ss| {
                if (std.mem.startsWith(u8, combined_path, ss.source.local_dir)) {
                    var rel_path = combined_path[ss.source.local_dir.len..];
                    if (rel_path.len > 0 and (rel_path[0] == '/' or rel_path[0] == '\\')) rel_path = rel_path[1..];

                    // Check if actually a file and get mtime
                    const stat = std.Io.Dir.cwd().statFile(lw.io, combined_path, .{}) catch |err| {
                        if (err != error.FileNotFound) {
                            std.debug.print("Error stating file {s}: {}\n", .{ rel_path, err });
                        }
                        break;
                    };
                    if (stat.kind == .directory) {
                        const full_dest = std.fs.path.join(allocator, &[_][]const u8{ lw.lw_config.dest_dir, rel_path }) catch break;
                        defer allocator.free(full_dest);
                        std.Io.Dir.cwd().createDirPath(lw.io, full_dest) catch |err| {
                            std.debug.print("Error creating directory {s}: {}\n", .{ full_dest, err });
                        };
                        break;
                    }

                    const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));

                    // Check hash before copying
                    const is_text = checksum_utils.isTextFile(rel_path, config.text_extensions);
                    const hash = checksum_utils.calculateFileChecksum(allocator, lw.io, combined_path, is_text) catch |err| {
                        std.debug.print("Error calculating hash for {s}: {}\n", .{ rel_path, err });
                        break;
                    };

                    const full_dest = std.fs.path.join(allocator, &[_][]const u8{ lw.lw_config.dest_dir, rel_path }) catch |err| {
                        std.debug.print("Error joining path for {s}: {}\n", .{ rel_path, err });
                        break;
                    };
                    defer allocator.free(full_dest);

                    var skip = false;
                    if (lw.checksum_db.get(rel_path)) |existing| {
                        if (existing.hash == hash) {
                            skip = true;
                        }
                    }

                    if (!skip) {
                        // Check if file already exists in destination and has same hash
                        if (std.Io.Dir.cwd().statFile(lw.io, full_dest, .{})) |dest_stat| {
                            if (dest_stat.size == stat.size) {
                                const dest_hash = checksum_utils.calculateFileChecksum(allocator, lw.io, full_dest, is_text) catch 0;
                                if (dest_hash == hash) skip = true;
                            }
                        } else |_| {}
                    }

                    if (!skip) {
                        lw.copyFile(ss.source.local_dir, rel_path) catch |err| {
                            std.debug.print("Error copying {s}: {}\n", .{ rel_path, err });
                        };
                    }
                    lw.checksum_db.put(rel_path, hash, mtime) catch {};
                    break;
                }
            }

            allocator.free(combined_path);
        }
        ready_paths.clearRetainingCapacity();

        lw.io.sleep(.{ .nanoseconds = 50 * std.time.ns_per_ms }, .real) catch {};
    }
}
