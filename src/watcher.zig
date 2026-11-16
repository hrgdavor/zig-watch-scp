// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const common = @import("watcher_common.zig");
const WatchBackend = @import("config.zig").WatchBackend;
const NightwatchWatcher = @import("watcher_nightwatch.zig").NightwatchWatcher;

pub const FileChange = common.FileChange;
pub const ChangeKind = common.ChangeKind;

pub const Backend = WatchBackend;

pub const Options = struct {
    backend: WatchBackend = .nightwatch,
    fsmeta_socket: ?[]const u8 = null,
};

/// A runtime-selected watcher. The nightwatch path is implemented; the fs-meta
/// socket path is a documented seam for the next integration step.
pub const Watcher = union(enum) {
    nightwatch: *NightwatchWatcher,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        options: Options,
    ) !Watcher {
        return switch (options.backend) {
            .nightwatch => .{ .nightwatch = try NightwatchWatcher.create(allocator, io, path) },
            .fsmeta => {
                std.debug.print(
                    "fs-meta watcher backend is not implemented yet (socket: {s})\n",
                    .{options.fsmeta_socket orelse "<unset>"},
                );
                return error.FsMetaBackendNotImplemented;
            },
        };
    }

    pub fn deinit(self: *Watcher) void {
        switch (self.*) {
            .nightwatch => |watcher| watcher.deinit(),
        }
    }

    pub fn wait(self: *Watcher, timeout_ms: u32) !void {
        switch (self.*) {
            .nightwatch => |watcher| try watcher.wait(timeout_ms),
        }
    }

    pub fn nextEvent(self: *Watcher) !?FileChange {
        return switch (self.*) {
            .nightwatch => |watcher| watcher.nextEvent(),
        };
    }
};
