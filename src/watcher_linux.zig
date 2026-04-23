// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const watcher = @import("watcher.zig");

const c = @cImport({
    @cInclude("sys/inotify.h");
    @cInclude("unistd.h");
    @cInclude("limits.h");
});

pub const LinuxWatcher = struct {
    allocator: std.mem.Allocator,
    inotify_fd: i32,
    watch_descriptors: std.AutoHashMap(i32, []const u8),
    base_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !LinuxWatcher {
        const inotify_fd = c.inotify_init1(c.IN_NONBLOCK);
        if (inotify_fd < 0) {
            return error.InotifyInitFailed;
        }

        var self = LinuxWatcher{
            .allocator = allocator,
            .inotify_fd = inotify_fd,
            .watch_descriptors = std.AutoHashMap(i32, []const u8).init(allocator),
            .base_path = try allocator.dupe(u8, path),
        };

        try self.addWatchRecursive(path);
        return self;
    }

    pub fn deinit(self: *LinuxWatcher) void {
        var it = self.watch_descriptors.valueIterator();
        while (it.next()) |path| {
            self.allocator.free(path.*);
        }
        self.watch_descriptors.deinit();
        self.allocator.free(self.base_path);
        _ = c.close(self.inotify_fd);
    }

    fn addWatchRecursive(self: *LinuxWatcher, path: []const u8) !void {
        try self.addWatch(path);

        const dir = std.Io.Dir.cwd().openDir(path, .{ .iterate = true }) catch return;
        var dir_copy = dir;
        defer dir_copy.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .directory) {
                const subpath = try std.fs.path.join(self.allocator, &[_][]const u8{ path, entry.name });
                defer self.allocator.free(subpath);
                try self.addWatchRecursive(subpath);
            }
        }
    }

    fn addWatch(self: *LinuxWatcher, path: []const u8) !void {
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const mask = c.IN_CREATE | c.IN_MODIFY | c.IN_DELETE | c.IN_MOVED_FROM | c.IN_MOVED_TO;
        const wd = c.inotify_add_watch(self.inotify_fd, path_z.ptr, mask);
        if (wd < 0) {
            return error.InotifyAddWatchFailed;
        }

        const owned_path = try self.allocator.dupe(u8, path);
        try self.watch_descriptors.put(wd, owned_path);
    }

    pub fn nextEvent(self: *LinuxWatcher) !?watcher.FileChange {
        var buffer: [4096]u8 align(@alignOf(c.inotify_event)) = undefined;

        const len = c.read(self.inotify_fd, &buffer, buffer.len);
        if (len < 0) {
            const err = std.posix.errno(len);
            if (err == .AGAIN) {
                return null;
            }
            return error.ReadFailed;
        }

        if (len == 0) return null;

        var offset: usize = 0;
        while (offset < len) {
            const event: *const c.inotify_event = @ptrCast(@alignCast(&buffer[offset]));
            offset += @sizeOf(c.inotify_event) + event.len;

            if (event.len == 0) continue;

            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buffer[offset - event.len])), 0);
            const watch_path = self.watch_descriptors.get(event.wd) orelse continue;

            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ watch_path, name });
            defer self.allocator.free(full_path);

            // Get relative path
            const rel_path = if (std.mem.startsWith(u8, full_path, self.base_path))
                full_path[self.base_path.len..]
            else
                full_path;

            const rel_path_trimmed = std.mem.trimStart(u8, rel_path, "/\\");
            const owned_rel_path = try self.allocator.dupe(u8, rel_path_trimmed);

            const kind: watcher.ChangeKind = if (event.mask & c.IN_CREATE != 0 or event.mask & c.IN_MOVED_TO != 0)
                .created
            else if (event.mask & c.IN_MODIFY != 0)
                .modified
            else if (event.mask & c.IN_DELETE != 0 or event.mask & c.IN_MOVED_FROM != 0)
                .deleted
            else
                continue;

            // If a directory was created, add watch for it
            if (event.mask & c.IN_ISDIR != 0 and kind == .created) {
                self.addWatchRecursive(full_path) catch {};
            }

            return watcher.FileChange{
                .path = owned_rel_path,
                .kind = kind,
            };
        }

        return null;
    }

    pub fn wait(self: *LinuxWatcher, timeout_ms: u32) !void {
        var fds = [_]std.posix.pollfd{.{
            .fd = self.inotify_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        _ = try std.posix.poll(&fds, @as(i32, @intCast(timeout_ms)));
    }
};
