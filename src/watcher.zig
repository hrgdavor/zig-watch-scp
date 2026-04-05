// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const builtin = @import("builtin");

pub const FileChange = struct {
    path: []const u8,
    kind: ChangeKind,
};

pub const ChangeKind = enum {
    created,
    modified,
    deleted,
};

pub const Watcher = switch (builtin.os.tag) {
    .linux => @import("watcher_linux.zig").LinuxWatcher,
    .windows => @import("watcher_windows.zig").WindowsWatcher,
    .macos => @import("watcher_macos.zig").MacOsWatcher,
    else => @compileError("Unsupported platform for file watching"),
};
