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

pub const Watcher = if (builtin.os.tag == .linux)
    @import("watcher_linux.zig").LinuxWatcher
else if (builtin.os.tag == .windows)
    @import("watcher_windows.zig").WindowsWatcher
else if (builtin.os.tag == .macos)
    @import("watcher_macos.zig").MacOsWatcher
else
    @compileError("Unsupported platform for file watching");
