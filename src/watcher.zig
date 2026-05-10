// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("config");
const common = @import("watcher_common.zig");

pub const FileChange = common.FileChange;
pub const ChangeKind = common.ChangeKind;

pub const Watcher = if (build_options.use_nightwatch) @import("watcher_nightwatch.zig").NightwatchWatcher else switch (builtin.os.tag) {
    .linux => @import("watcher_linux.zig").LinuxWatcher,
    .windows => @import("watcher_windows.zig").WindowsWatcher,
    .macos => @import("watcher_macos.zig").MacOsWatcher,
    else => @compileError("Unsupported platform for file watching"),
};
