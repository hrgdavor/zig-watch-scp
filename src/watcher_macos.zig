// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const watcher = @import("watcher.zig");
const bopts = @import("build_options");

// Only compile CoreServices C headers when building natively on macOS.
// Cross-compiled builds (e.g. from Windows) fall back to a polling watcher.
const c = @import("c");

pub const MacOsWatcher = if (bopts.use_coreservices) struct {
    // --- FSEvents implementation (native macOS build) ---
    allocator: std.mem.Allocator,
    base_path: []const u8,
    stream: c.FSEventStreamRef,
    run_loop: c.CFRunLoopRef,
    event_queue: std.ArrayList(watcher.FileChange),
    mutex: std.Io.Mutex,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !@This() {
        const path_cfstring = c.CFStringCreateWithCString(
            null,
            path.ptr,
            c.kCFStringEncodingUTF8,
        ) orelse return error.CFStringCreateFailed;
        defer c.CFRelease(path_cfstring);

        const paths_array = c.CFArrayCreate(
            null,
            @ptrCast(@constCast(&path_cfstring)),
            1,
            null,
        ) orelse return error.CFArrayCreateFailed;
        defer c.CFRelease(paths_array);

        var self = @This(){
            .allocator = allocator,
            .base_path = try allocator.dupe(u8, path),
            .stream = undefined,
            .run_loop = undefined,
            .event_queue = std.ArrayList(watcher.FileChange).empty,
            .mutex = std.Io.Mutex.init,
            .io = io,
        };

        var context = c.FSEventStreamContext{
            .version = 0,
            .info = @ptrCast(&self),
            .retain = null,
            .release = null,
            .copyDescription = null,
        };

        self.stream = c.FSEventStreamCreate(
            null,
            fseventsCallback,
            &context,
            paths_array,
            c.kFSEventStreamEventIdSinceNow,
            0.1,
            c.kFSEventStreamCreateFlagFileEvents | c.kFSEventStreamCreateFlagNoDefer,
        ) orelse return error.FSEventStreamCreateFailed;

        self.run_loop = c.CFRunLoopGetCurrent();
        c.FSEventStreamScheduleWithRunLoop(self.stream, self.run_loop, c.kCFRunLoopDefaultMode);

        if (c.FSEventStreamStart(self.stream) == 0) {
            c.CFRelease(self.stream);
            return error.FSEventStreamStartFailed;
        }

        return self;
    }

    pub fn deinit(self: *@This()) void {
        c.FSEventStreamStop(self.stream);
        c.FSEventStreamInvalidate(self.stream);
        c.FSEventStreamRelease(self.stream);

        for (self.event_queue.items) |event| {
            self.allocator.free(event.path);
        }
        self.event_queue.deinit(self.allocator);
        self.allocator.free(self.base_path);
    }

    fn fseventsCallback(
        streamRef: c.ConstFSEventStreamRef,
        clientCallBackInfo: ?*anyopaque,
        numEvents: usize,
        eventPaths: ?*anyopaque,
        eventFlags: [*c]const c.FSEventStreamEventFlags,
        eventIds: [*c]const c.FSEventStreamEventId,
    ) callconv(.c) void {
        _ = streamRef;
        _ = eventIds;

        const self: *@This() = @ptrCast(@alignCast(clientCallBackInfo));
        const paths: [*][*:0]const u8 = @ptrCast(@alignCast(eventPaths));

        var i: usize = 0;
        while (i < numEvents) : (i += 1) {
            const path = std.mem.span(paths[i]);
            const flags = eventFlags[i];

            const rel_path = if (std.mem.startsWith(u8, path, self.base_path))
                path[self.base_path.len..]
            else
                path;

            const rel_path_trimmed = std.mem.trimStart(u8, rel_path, "/");

            const kind: watcher.ChangeKind = if (flags & c.kFSEventStreamEventFlagItemCreated != 0)
                .created
            else if (flags & c.kFSEventStreamEventFlagItemRemoved != 0)
                .deleted
            else if (flags & c.kFSEventStreamEventFlagItemModified != 0)
                .modified
            else
                continue;

            const owned_path = self.allocator.dupe(u8, rel_path_trimmed) catch continue;

            self.mutex.lock();
            defer self.mutex.unlock();

            self.event_queue.append(self.allocator, .{
                .path = owned_path,
                .kind = kind,
            }) catch {
                self.allocator.free(owned_path);
            };
        }
    }

    pub fn nextEvent(self: *@This()) !?watcher.FileChange {
        _ = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, 0.01, 1);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.event_queue.items.len > 0) {
            return self.event_queue.orderedRemove(0);
        }

        return null;
    }

    pub fn wait(self: *@This(), timeout_ms: u32) !void {
        _ = self;
        const timeout_seconds: f64 = @as(f64, @floatFromInt(timeout_ms)) / 1000.0;
        _ = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, timeout_seconds, 0);
    }
} else struct {
    // --- Polling fallback for cross-compiled macOS builds (no CoreServices SDK) ---
    const FileState = struct { mtime_ns: i128 };

    allocator: std.mem.Allocator,
    base_path: []const u8,
    state: std.StringHashMap(FileState),
    pending: std.ArrayList(watcher.FileChange),
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !@This() {
        var self = @This(){
            .allocator = allocator,
            .base_path = try allocator.dupe(u8, path),
            .state = std.StringHashMap(FileState).init(allocator),
            .pending = std.ArrayList(watcher.FileChange).empty,
            .io = io,
        };
        errdefer allocator.free(self.base_path);
        errdefer self.state.deinit();
        try self.scanInto(path, &self.state);
        return self;
    }

    pub fn deinit(self: *@This()) void {
        var it = self.state.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.state.deinit();
        for (self.pending.items) |event| self.allocator.free(event.path);
        self.pending.deinit(self.allocator);
        self.allocator.free(self.base_path);
    }

    fn scanInto(self: *@This(), path: []const u8, out: *std.StringHashMap(FileState)) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            const full = try std.fs.path.join(self.allocator, &.{ path, entry.name });
            defer self.allocator.free(full);
            const rel = std.mem.trimStart(u8, full[self.base_path.len..], "/");
            if (entry.kind == .file) {
                const stat = std.Io.Dir.cwd().statFile(self.io, full, .{}) catch continue;
                const key = try self.allocator.dupe(u8, rel);
                try out.put(key, .{ .mtime_ns = stat.mtime });
            } else if (entry.kind == .directory) {
                try self.scanInto(full, out);
            }
        }
    }

    fn poll(self: *@This()) !void {
        var new_state = std.StringHashMap(FileState).init(self.allocator);
        errdefer {
            var nit = new_state.keyIterator();
            while (nit.next()) |key| self.allocator.free(key.*);
            new_state.deinit();
        }
        try self.scanInto(self.base_path, &new_state);

        // Detect modified and created
        var nit = new_state.iterator();
        while (nit.next()) |entry| {
            const key = entry.key_ptr.*;
            if (self.state.get(key)) |old| {
                if (entry.value_ptr.mtime_ns != old.mtime_ns) {
                    try self.pending.append(self.allocator, .{
                        .path = try self.allocator.dupe(u8, key),
                        .kind = .modified,
                    });
                }
            } else {
                try self.pending.append(self.allocator, .{
                    .path = try self.allocator.dupe(u8, key),
                    .kind = .created,
                });
            }
        }

        // Detect deleted
        var oit = self.state.keyIterator();
        while (oit.next()) |key| {
            if (!new_state.contains(key.*)) {
                try self.pending.append(self.allocator, .{
                    .path = try self.allocator.dupe(u8, key.*),
                    .kind = .deleted,
                });
            }
        }

        // Swap state: free old keys, adopt new_state
        var old_it = self.state.keyIterator();
        while (old_it.next()) |key| self.allocator.free(key.*);
        self.state.deinit();
        self.state = new_state;
    }

    pub fn nextEvent(self: *@This()) anyerror!?watcher.FileChange {
        if (self.pending.items.len == 0) try self.poll();
        if (self.pending.items.len > 0) return self.pending.orderedRemove(0);
        return null;
    }

    pub fn wait(self: *@This(), timeout_ms: u32) !void {
        std.Thread.sleep(@as(u64, timeout_ms) * std.time.ns_per_ms);
        try self.poll();
    }
};
