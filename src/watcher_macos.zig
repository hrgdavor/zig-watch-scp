// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const watcher = @import("watcher.zig");

const c = @cImport({
    @cInclude("CoreServices/CoreServices.h");
});

pub const MacOsWatcher = struct {
    allocator: std.mem.Allocator,
    base_path: []const u8,
    stream: c.FSEventStreamRef,
    run_loop: c.CFRunLoopRef,
    event_queue: std.ArrayList(watcher.FileChange),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !MacOsWatcher {
        const path_cfstring = c.CFStringCreateWithCString(
            null,
            path.ptr,
            c.kCFStringEncodingUTF8,
        ) orelse return error.CFStringCreateFailed;
        defer c.CFRelease(path_cfstring);

        const paths_array = c.CFArrayCreate(
            null,
            @ptrCast(&path_cfstring),
            1,
            null,
        ) orelse return error.CFArrayCreateFailed;
        defer c.CFRelease(paths_array);

        var self = MacOsWatcher{
            .allocator = allocator,
            .base_path = try allocator.dupe(u8, path),
            .stream = undefined,
            .run_loop = undefined,
            .event_queue = std.ArrayList(watcher.FileChange).empty,
            .mutex = std.Thread.Mutex{},
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
            0.1, // latency in seconds
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

    pub fn deinit(self: *MacOsWatcher) void {
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
    ) callconv(.C) void {
        _ = streamRef;
        _ = eventIds;

        const self: *MacOsWatcher = @ptrCast(@alignCast(clientCallBackInfo));
        const paths: [*][*:0]const u8 = @ptrCast(@alignCast(eventPaths));

        var i: usize = 0;
        while (i < numEvents) : (i += 1) {
            const path = std.mem.span(paths[i]);
            const flags = eventFlags[i];

            // Get relative path
            const rel_path = if (std.mem.startsWith(u8, path, self.base_path))
                path[self.base_path.len..]
            else
                path;

            const rel_path_trimmed = std.mem.trimLeft(u8, rel_path, "/");

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

    pub fn nextEvent(self: *MacOsWatcher) !?watcher.FileChange {
        // Run the run loop briefly to process events
        _ = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, 0.01, 1);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.event_queue.items.len > 0) {
            return self.event_queue.orderedRemove(0);
        }

        return null;
    }

    pub fn wait(self: *MacOsWatcher, timeout_ms: u32) !void {
        _ = self;
        const timeout_seconds: f64 = @as(f64, @floatFromInt(timeout_ms)) / 1000.0;
        _ = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, timeout_seconds, 0);
    }
};
