// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");

pub const DbEntry = struct {
    hash: u64,
    mtime: i64,
    size: u64,
};

pub const ChecksumDb = struct {
    entries: std.StringHashMap(DbEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ChecksumDb {
        return .{
            .entries = std.StringHashMap(DbEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ChecksumDb) void {
        self.clear();
        self.entries.deinit();
    }

    pub fn clear(self: *ChecksumDb) void {
        var it = self.entries.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn put(self: *ChecksumDb, path: []const u8, hash: u64, mtime: i64, size: u64) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        std.mem.replaceScalar(u8, owned_path, '\\', '/');
        const gop = try self.entries.getOrPut(owned_path);
        if (gop.found_existing) {
            self.allocator.free(owned_path); // Use the existing key instead
        }
        gop.value_ptr.* = .{ .hash = hash, .mtime = mtime, .size = size };
    }

    pub fn get(self: *const ChecksumDb, path: []const u8) ?DbEntry {
        return self.entries.get(path);
    }

    pub fn serialize(self: *const ChecksumDb, writer: anytype) !void {
        const Entry = struct { path: []const u8, hash: u64, mtime: i64, size: u64 };
        var list = std.ArrayList(Entry).empty;
        defer list.deinit(self.allocator);

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            try list.append(self.allocator, .{
                .path = entry.key_ptr.*,
                .hash = entry.value_ptr.hash,
                .mtime = entry.value_ptr.mtime,
                .size = entry.value_ptr.size,
            });
        }

        const SortContext = struct {
            pub fn lessThan(_: @This(), a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        };

        std.sort.block(Entry, list.items, SortContext{}, SortContext.lessThan);

        for (list.items) |entry| {
            try writer.print("{x:0>16}\t{d}\t{d}\t{s}\n", .{ entry.hash, entry.mtime, entry.size, entry.path });
        }
    }

    pub fn deserialize(allocator: std.mem.Allocator, content: []const u8) !ChecksumDb {
        var db = ChecksumDb.init(allocator);
        errdefer db.deinit();

        var lines = std.mem.splitScalar(u8, content, '\n');
        var corrupted_count: usize = 0;
        var first_corrupted_line: ?[]const u8 = null;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;

            var it = std.mem.splitScalar(u8, trimmed, '\t');
            const hash_str = it.next() orelse {
                corrupted_count += 1;
                continue;
            };
            const mtime_str = it.next() orelse {
                corrupted_count += 1;
                continue;
            };
            const next_part = it.next() orelse {
                corrupted_count += 1;
                continue;
            };

            var size: u64 = 0;
            var path: []const u8 = "";

            if (it.next()) |p| {
                // We have 4 parts: hash, mtime, size, path
                size = std.fmt.parseInt(u64, next_part, 10) catch {
                    corrupted_count += 1;
                    continue;
                };
                path = p;
            } else {
                // Backward compatibility: 3 parts: hash, mtime, path
                path = next_part;
            }

            const hash = std.fmt.parseInt(u64, hash_str, 16) catch {
                corrupted_count += 1;
                if (first_corrupted_line == null) first_corrupted_line = trimmed;
                continue;
            };
            const mtime = std.fmt.parseInt(i64, mtime_str, 10) catch {
                corrupted_count += 1;
                if (first_corrupted_line == null) first_corrupted_line = trimmed;
                continue;
            };

            try db.put(path, hash, mtime, size);
        }

        if (corrupted_count > 0) {
            std.debug.print("Warning: Skipped {d} corrupted line(s) in checksum database.\n", .{corrupted_count});
            std.debug.print("Expected format: checksum\ttimestamp\tpath\n", .{});
            if (first_corrupted_line) |line| {
                std.debug.print("First corrupted line: {s}\n", .{line});
            }
            std.debug.print("Continuing with partial database...\n\n", .{});
        }

        return db;
    }
};

/// Calculate checksum for a file, normalizing line endings for text files
pub fn calculateFileChecksum(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    is_text_file: bool,
) !u64 {
    if (is_text_file) {
        // For text files, we still need to load and normalize
        // Increase limit to 1GB for text files
        const content = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, @as(std.Io.Limit, @enumFromInt(1024 * 1024 * 1024)));
        defer allocator.free(content);

        const normalized = try normalizeLineEndings(allocator, content);
        defer allocator.free(normalized);
        return std.hash.Wyhash.hash(0, normalized);
    } else {
        const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
        defer file.close(io);

        // For binary files, use streaming to handle any size efficiently
        var hasher = std.hash.Wyhash.init(0);
        var buffer: [12 * 1024]u8 = undefined;
        var reader_buf: [4096]u8 = undefined;
        var reader = file.reader(io, &reader_buf);
        while (true) {
            var slices = [1][]u8{buffer[0..]};
            const bytes_read = reader.interface.readVec(slices[0..]) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (bytes_read == 0) break;
            hasher.update(buffer[0..bytes_read]);
        }
        return hasher.final();
    }
}

fn normalizeLineEndings(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        if (i + 1 < content.len and content[i] == '\r' and content[i + 1] == '\n') {
            // Skip \r, keep \n
            try result.append(allocator, '\n');
            i += 2;
        } else if (content[i] == '\r') {
            // Standalone \r -> \n
            try result.append(allocator, '\n');
            i += 1;
        } else {
            try result.append(allocator, content[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

pub fn isTextFile(file_path: []const u8, text_extensions: []const []const u8) bool {
    for (text_extensions) |ext| {
        if (std.mem.endsWith(u8, file_path, ext)) {
            return true;
        }
    }
    return false;
}
