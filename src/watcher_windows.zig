// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const watcher_common = @import("watcher_common.zig");
const windows = std.os.windows;

// Windows constants removed from std.os.windows in Zig 0.16
const FILE_LIST_DIRECTORY: u32 = 0x00000001;
const FILE_SHARE_READ: u32 = 0x00000001;
const FILE_SHARE_WRITE: u32 = 0x00000002;
const FILE_SHARE_DELETE: u32 = 0x00000004;
const OPEN_EXISTING: u32 = 3;
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
const FILE_FLAG_OVERLAPPED: u32 = 0x40000000;

/// OVERLAPPED is no longer in std.os.windows in Zig 0.16; define it locally.
const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: u32,
            OffsetHigh: u32,
        },
        Pointer: ?*anyopaque,
    } = .{ .DUMMYSTRUCTNAME = .{ .Offset = 0, .OffsetHigh = 0 } },
    hEvent: ?windows.HANDLE = null,
};

extern "kernel32" fn CreateFileW(
    lpFileName: windows.LPCWSTR,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) ?windows.HANDLE;

const FILE_NOTIFY_INFORMATION = extern struct {
    NextEntryOffset: u32,
    Action: u32,
    FileNameLength: u32,
    // FileName follows as WCHAR array
};

const FILE_ACTION_ADDED = 0x00000001;
const FILE_ACTION_REMOVED = 0x00000002;
const FILE_ACTION_MODIFIED = 0x00000003;
const FILE_ACTION_RENAMED_OLD_NAME = 0x00000004;
const FILE_ACTION_RENAMED_NEW_NAME = 0x00000005;

const FILE_NOTIFY_CHANGE_FILE_NAME = 0x00000001;
const FILE_NOTIFY_CHANGE_DIR_NAME = 0x00000002;
const FILE_NOTIFY_CHANGE_ATTRIBUTES = 0x00000004;
const FILE_NOTIFY_CHANGE_SIZE = 0x00000008;
const FILE_NOTIFY_CHANGE_LAST_WRITE = 0x00000010;
const FILE_NOTIFY_CHANGE_CREATION = 0x00000040;

extern "kernel32" fn ReadDirectoryChangesW(
    hDirectory: windows.HANDLE,
    lpBuffer: [*]u8,
    nBufferLength: u32,
    bWatchSubtree: windows.BOOL,
    dwNotifyFilter: u32,
    lpBytesReturned: ?*u32,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRoutine: ?*const anyopaque,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetOverlappedResult(
    hUint: windows.HANDLE,
    lpOverlapped: *OVERLAPPED,
    lpNumberOfBytesTransferred: *u32,
    bWait: windows.BOOL,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*anyopaque,
    bManualReset: windows.BOOL,
    bInitialState: windows.BOOL,
    lpName: ?windows.LPWSTR,
) callconv(.winapi) ?windows.HANDLE;

extern "kernel32" fn WaitForSingleObject(
    hHandle: windows.HANDLE,
    dwMilliseconds: u32,
) callconv(.winapi) u32;

pub const WindowsWatcher = struct {
    allocator: std.mem.Allocator,
    dir_handle: windows.HANDLE,
    buffer: []align(@alignOf(FILE_NOTIFY_INFORMATION)) u8,
    base_path: []const u8,
    bytes_returned: u32,
    current_offset: usize,
    overlapped: OVERLAPPED,
    io_pending: bool,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !WindowsWatcher {
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
        defer allocator.free(path_w);

        const dir_handle = CreateFileW(
            path_w.ptr,
            FILE_LIST_DIRECTORY,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            null,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
            null,
        ) orelse {
            return error.OpenDirectoryFailed;
        };

        const buffer = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(FILE_NOTIFY_INFORMATION)), 64 * 1024);

        // Auto-reset event (bManualReset = windows.BOOL.FALSE)
        const event_handle = CreateEventW(null, windows.BOOL.FALSE, windows.BOOL.FALSE, null) orelse {
            windows.CloseHandle(dir_handle);
            allocator.free(buffer);
            return error.CreateEventFailed;
        };

        return WindowsWatcher{
            .allocator = allocator,
            .dir_handle = dir_handle,
            .buffer = buffer,
            .base_path = try allocator.dupe(u8, path),
            .bytes_returned = 0,
            .current_offset = 0,
            .overlapped = std.mem.zeroInit(OVERLAPPED, .{ .hEvent = event_handle }),
            .io_pending = false,
            .io = io,
        };
    }

    pub fn deinit(self: *WindowsWatcher) void {
        windows.CloseHandle(self.dir_handle);
        if (self.overlapped.hEvent) |h| windows.CloseHandle(h);
        self.allocator.free(self.buffer);
        self.allocator.free(self.base_path);
    }

    fn startRead(self: *WindowsWatcher) !void {
        // Clear status fields of overlapped structure before reuse
        self.overlapped.Internal = 0;
        self.overlapped.InternalHigh = 0;
        self.overlapped.DUMMYUNIONNAME = .{ .DUMMYSTRUCTNAME = .{ .Offset = 0, .OffsetHigh = 0 } };

        const filter = FILE_NOTIFY_CHANGE_FILE_NAME |
            FILE_NOTIFY_CHANGE_DIR_NAME |
            FILE_NOTIFY_CHANGE_SIZE |
            FILE_NOTIFY_CHANGE_LAST_WRITE |
            FILE_NOTIFY_CHANGE_CREATION;

        const result = ReadDirectoryChangesW(
            self.dir_handle,
            self.buffer.ptr,
            @intCast(self.buffer.len),
            windows.BOOL.TRUE, // watch subtree
            filter,
            null,
            &self.overlapped,
            null,
        );

        if (!result.toBool()) {
            const err = windows.GetLastError();
            if (err != .IO_PENDING) {
                std.debug.print("ReadDirectoryChangesW failed: {}\n", .{err});
                return error.ReadDirectoryChangesFailed;
            }
        }
        self.io_pending = true;
    }

    pub fn nextEvent(self: *WindowsWatcher) anyerror!?watcher_common.FileChange {
        // If we have buffered events, process them first
        if (self.current_offset < self.bytes_returned) {
            return try self.processNextBufferedEvent();
        }

        if (!self.io_pending) {
            try self.startRead();
            return null;
        }

        // Check if I/O has completed
        var transferred: u32 = 0;
        if (!GetOverlappedResult(self.dir_handle, &self.overlapped, &transferred, windows.BOOL.FALSE).toBool()) {
            const err = windows.GetLastError();
            if (err == .IO_INCOMPLETE) {
                return null;
            }
            std.debug.print("GetOverlappedResult failed: {}\n", .{err});
            return error.ReadDirectoryChangesFailed;
        }

        self.io_pending = false;
        self.bytes_returned = transferred;
        self.current_offset = 0;

        if (self.bytes_returned == 0) {
            try self.startRead();
            return null;
        }

        return try self.processNextBufferedEvent();
    }

    fn processNextBufferedEvent(self: *WindowsWatcher) anyerror!?watcher_common.FileChange {
        if (self.current_offset >= self.bytes_returned) {
            try self.startRead();
            return null;
        }

        const info: *const FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(&self.buffer[self.current_offset]));

        const filename_bytes = self.buffer[self.current_offset + @sizeOf(FILE_NOTIFY_INFORMATION) ..][0..info.FileNameLength];
        const filename_u16 = std.mem.bytesAsSlice(u16, @as([]align(2) u8, @alignCast(filename_bytes)));

        const filename = try std.unicode.utf16LeToUtf8Alloc(self.allocator, filename_u16);
        // Convert backslashes to forward slashes
        for (filename) |*c| {
            if (c.* == '\\') c.* = '/';
        }

        const kind: watcher_common.ChangeKind = switch (info.Action) {
            FILE_ACTION_ADDED, FILE_ACTION_RENAMED_NEW_NAME => .created,
            FILE_ACTION_MODIFIED => .modified,
            FILE_ACTION_REMOVED, FILE_ACTION_RENAMED_OLD_NAME => .deleted,
            else => {
                self.allocator.free(filename);
                if (info.NextEntryOffset == 0) {
                    self.current_offset = self.bytes_returned;
                } else {
                    self.current_offset += info.NextEntryOffset;
                }
                return try self.nextEvent();
            },
        };

        if (info.NextEntryOffset == 0) {
            self.current_offset = self.bytes_returned;
        } else {
            self.current_offset += info.NextEntryOffset;
        }

        return watcher_common.FileChange{
            .path = filename,
            .kind = kind,
        };
    }

    pub fn wait(self: *WindowsWatcher, timeout_ms: u32) !void {
        if (!self.io_pending) return;
        _ = WaitForSingleObject(self.overlapped.hEvent.?, timeout_ms);
    }
};
