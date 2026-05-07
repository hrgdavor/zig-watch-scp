const std = @import("std");
const nightwatch = @import("nightwatch");
const common = @import("watcher_common.zig");

pub const NightwatchWatcher = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    base_path: []const u8,
    watcher: nightwatch.Default,
    handler: Handler,
    event_queue: std.ArrayList(common.FileChange),
    mutex: std.Io.Mutex,
    event_count: std.atomic.Value(u32),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !NightwatchWatcher {
        const resolved_path = try std.fs.path.resolve(allocator, &.{path});
        defer allocator.free(resolved_path);

        var self = NightwatchWatcher{
            .allocator = allocator,
            .io = io,
            .base_path = try allocator.dupe(u8, resolved_path),
            .watcher = undefined,
            .handler = Handler{ .handler = .{ .vtable = &Handler.vtable } },
            .event_queue = std.ArrayList(common.FileChange).empty,
            .mutex = std.Io.Mutex.init,
            .event_count = .init(0),
        };

        var cleanup = true;
        defer blk: {
            if (!cleanup) break :blk;
            self.allocator.free(self.base_path);
            self.event_queue.deinit(self.allocator);
        }

        self.watcher = try nightwatch.Default.init(io, allocator, &self.handler.handler);
        defer blk2: {
            if (!cleanup) break :blk2;
            self.watcher.deinit();
        }

        try self.watcher.watch(resolved_path);
        cleanup = false;
        return self;
    }

    pub fn deinit(self: *NightwatchWatcher) void {
        self.watcher.deinit();
        for (self.event_queue.items) |event| {
            self.allocator.free(event.path);
        }
        self.event_queue.deinit(self.allocator);
        self.allocator.free(self.base_path);
    }

    pub fn nextEvent(self: *NightwatchWatcher) !?common.FileChange {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.event_queue.items.len == 0) return null;
        return self.event_queue.orderedRemove(0);
    }

    pub fn wait(self: *NightwatchWatcher, timeout_ms: u32) !void {
        if (timeout_ms == 0) return;
        // Load snapshot before checking queue to avoid missing a wakeup:
        // if an event arrives after the snapshot load, event_count will differ
        // and futexWaitTimeout returns immediately without sleeping.
        const snapshot = self.event_count.load(.monotonic);
        self.mutex.lockUncancelable(self.io);
        const has_events = self.event_queue.items.len != 0;
        self.mutex.unlock(self.io);
        if (has_events) return;
        try self.io.futexWaitTimeout(u32, &self.event_count.raw, snapshot, .{
            .duration = .{
                .raw = .fromNanoseconds(@as(i96, timeout_ms) * std.time.ns_per_ms),
                .clock = .boot,
            },
        });
    }
};

const Handler = struct {
    handler: nightwatch.Default.Handler,

    const vtable = nightwatch.Default.Handler.VTable{
        .change = change_cb,
        .rename = rename_cb,
    };

    fn change_cb(h: *nightwatch.Default.Handler, path: []const u8, event_type: nightwatch.EventType, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        const self = @as(*Handler, @fieldParentPtr("handler", h));
        const watcher = @as(*NightwatchWatcher, @fieldParentPtr("handler", self));
        const kind = switch (event_type) {
            .created => common.ChangeKind.created,
            .modified => common.ChangeKind.modified,
            .deleted => common.ChangeKind.deleted,
            .closed => common.ChangeKind.modified,
        };
        try enqueueEvent(watcher, kind, path);
        return;
    }

    fn rename_cb(h: *nightwatch.Default.Handler, src: []const u8, dst: []const u8, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        const self = @as(*Handler, @fieldParentPtr("handler", h));
        const watcher = @as(*NightwatchWatcher, @fieldParentPtr("handler", self));
        try enqueueEvent(watcher, common.ChangeKind.deleted, src);
        try enqueueEvent(watcher, common.ChangeKind.created, dst);
        return;
    }
};

fn enqueueEvent(self: *NightwatchWatcher, kind: common.ChangeKind, path: []const u8) error{HandlerFailed}!void {
    const rel_path = normalizePath(self, path);
    const owned_path = self.allocator.dupe(u8, rel_path) catch return error.HandlerFailed;

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    self.event_queue.append(self.allocator, .{ .path = owned_path, .kind = kind }) catch {
        self.allocator.free(owned_path);
        return error.HandlerFailed;
    };
    _ = self.event_count.fetchAdd(1, .release);
    self.io.futexWake(u32, &self.event_count.raw, 1);
}

fn normalizePath(self: *NightwatchWatcher, absolute_path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, absolute_path, self.base_path)) {
        const rel = absolute_path[self.base_path.len..];
        return std.mem.trimStart(u8, rel, "/\\");
    }
    return absolute_path;
}
