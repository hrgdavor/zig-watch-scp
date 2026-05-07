// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const checksum_db = @import("checksum_db.zig");
const config_pkg = @import("config.zig");
const Config = config_pkg.Config;
const Folder = config_pkg.Folder;

pub const FileEntry = struct {
    path: []const u8,
    checksum: u64,
    mtime: i64,
    size: u64,
    is_text: bool,
};

pub const Scanner = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    folder: *const Folder,
    files: std.ArrayList(FileEntry),
    io: std.Io,
    mutex: std.Io.Mutex,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: *const Config, folder: *const Folder) Scanner {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .folder = folder,
            .files = std.ArrayList(FileEntry).empty,
            .mutex = std.Io.Mutex.init,
        };
    }

    pub fn deinit(self: *Scanner) void {
        for (self.files.items) |entry| {
            self.allocator.free(entry.path);
        }
        self.files.deinit(self.allocator);
    }

    pub fn scanDirectory(self: *Scanner) !void {
        const dir = try std.Io.Dir.cwd().openDir(self.io, self.folder.local_dir, .{ .iterate = true });
        var dir_copy = dir;
        defer dir_copy.close(self.io);
        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        // Collect all file paths first
        var file_paths = std.ArrayList([]const u8).empty;
        defer {
            for (file_paths.items) |path| {
                self.allocator.free(path);
            }
            file_paths.deinit(self.allocator);
        }

        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file) continue;

            // Check include/exclude patterns
            if (!self.shouldIncludeFile(entry.path)) continue;

            const path = try self.allocator.dupe(u8, entry.path);
            std.mem.replaceScalar(u8, path, '\\', '/');
            try file_paths.append(self.allocator, path);
        }

        // Process files in parallel
        const thread_count = @min(self.config.parallel_threads, file_paths.items.len);
        if (thread_count == 0) return;

        const chunk_size = (file_paths.items.len + thread_count - 1) / thread_count;

        var threads = try self.allocator.alloc(std.Thread, thread_count);
        defer self.allocator.free(threads);

        var i: usize = 0;
        while (i < thread_count) : (i += 1) {
            const start = i * chunk_size;
            const end = @min(start + chunk_size, file_paths.items.len);
            if (start >= file_paths.items.len) break;

            const context = ThreadContext{
                .scanner = self,
                .paths = file_paths.items[start..end],
            };

            threads[i] = try std.Thread.spawn(.{}, processFilesThread, .{context});
        }

        // Wait for all threads
        for (threads[0..i]) |thread| {
            thread.join();
        }
    }

    fn shouldIncludeFile(self: *Scanner, path: []const u8) bool {
        // Check exclude patterns
        for (self.folder.exclude_patterns) |pattern| {
            if (matchPattern(path, pattern)) return false;
        }

        // If include patterns specified, file must match at least one
        if (self.folder.include_patterns.len > 0) {
            for (self.folder.include_patterns) |pattern| {
                if (matchPattern(path, pattern)) return true;
            }
            return false;
        }

        return true;
    }

    pub fn matchPattern(path: []const u8, pattern: []const u8) bool {
        // Simple wildcard matching (* and ?)
        return matchPatternImpl(path, pattern);
    }

    pub fn matchPatternImpl(path: []const u8, pattern: []const u8) bool {
        var p_idx: usize = 0;
        var s_idx: usize = 0;

        while (p_idx < pattern.len) {
            // Check for **
            if (p_idx + 1 < pattern.len and pattern[p_idx] == '*' and pattern[p_idx + 1] == '*') {
                p_idx += 2;
                if (p_idx == pattern.len) return true; // ** at end matches everything

                // Pattern continues after **, e.g., **/foo
                if (pattern[p_idx] == '/' or pattern[p_idx] == '\\') {
                    p_idx += 1;
                    // Match any number of segments until the rest of the pattern matches
                    while (s_idx <= path.len) {
                        if (matchPatternImpl(path[s_idx..], pattern[p_idx..])) return true;
                        // Move to next segment
                        if (std.mem.indexOfAny(u8, path[s_idx..], "/\\")) |next| {
                            s_idx += next + 1;
                        } else {
                            break;
                        }
                    }
                    return false;
                }
                // Case like "foo**" - treat as "*"
            }

            // Normal segment matching
            const p_segment_end = std.mem.indexOfAny(u8, pattern[p_idx..], "/\\") orelse pattern.len - p_idx;
            const s_segment_end = std.mem.indexOfAny(u8, path[s_idx..], "/\\") orelse path.len - s_idx;

            if (!matchSegment(path[s_idx .. s_idx + s_segment_end], pattern[p_idx .. p_idx + p_segment_end])) {
                return false;
            }

            p_idx += p_segment_end;
            s_idx += s_segment_end;

            if (p_idx < pattern.len) {
                if (s_idx == path.len) return false;
                p_idx += 1; // skip separator
                s_idx += 1; // skip separator
            } else {
                return s_idx == path.len;
            }
        }
        return s_idx == path.len;
    }

    fn matchSegment(str: []const u8, pattern: []const u8) bool {
        var s_idx: usize = 0;
        var p_idx: usize = 0;
        var star_idx: ?usize = null;
        var match_idx: usize = 0;

        while (s_idx < str.len) {
            if (p_idx < pattern.len) {
                if (pattern[p_idx] == '*') {
                    star_idx = p_idx;
                    match_idx = s_idx;
                    p_idx += 1;
                    continue;
                } else if (pattern[p_idx] == '?' or pattern[p_idx] == str[s_idx]) {
                    s_idx += 1;
                    p_idx += 1;
                    continue;
                }
            }

            if (star_idx) |star| {
                p_idx = star + 1;
                match_idx += 1;
                s_idx = match_idx;
            } else {
                return false;
            }
        }

        while (p_idx < pattern.len and pattern[p_idx] == '*') {
            p_idx += 1;
        }

        return p_idx == pattern.len;
    }

    const ThreadContext = struct {
        scanner: *Scanner,
        paths: []const []const u8,
    };

    fn processFilesThread(context: ThreadContext) void {
        for (context.paths) |path| {
            processFile(context.scanner, path) catch |err| {
                std.debug.print("Error processing {s}: {}\n", .{ path, err });
            };
        }
    }

    fn processFile(scanner: *Scanner, rel_path: []const u8) !void {
        const full_path = try std.fs.path.join(scanner.allocator, &[_][]const u8{ scanner.folder.local_dir, rel_path });
        defer scanner.allocator.free(full_path);

        const stat = try std.Io.Dir.cwd().statFile(scanner.io, full_path, .{});
        const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));

        const is_text = checksum_db.isTextFile(rel_path, scanner.config.text_extensions);
        const checksum = try checksum_db.calculateFileChecksum(scanner.allocator, scanner.io, full_path, is_text);

        const owned_path = try scanner.allocator.dupe(u8, rel_path);

        try scanner.mutex.lock(scanner.io);
        defer scanner.mutex.unlock(scanner.io);

        try scanner.files.append(scanner.allocator, .{
            .path = owned_path,
            .checksum = checksum,
            .mtime = mtime,
            .size = stat.size,
            .is_text = is_text,
        });
    }

    pub fn getChangedFiles(self: *Scanner, remote_db: *const checksum_db.ChecksumDb) !std.ArrayList(FileEntry) {
        var changed = std.ArrayList(FileEntry).empty;

        for (self.files.items) |entry| {
            const remote_entry = remote_db.get(entry.path);
            var is_changed = false;
            if (remote_entry) |re| {
                if (self.folder.check == .mtime_size) {
                    is_changed = (re.mtime != entry.mtime or re.size != entry.size);
                } else {
                    is_changed = (re.hash != entry.checksum);
                }
            } else {
                is_changed = true;
            }

            if (is_changed) {
                const path_copy = try self.allocator.dupe(u8, entry.path);
                try changed.append(self.allocator, .{
                    .path = path_copy,
                    .checksum = entry.checksum,
                    .mtime = entry.mtime,
                    .size = entry.size,
                    .is_text = entry.is_text,
                });
            }
        }

        return changed;
    }
};
