const std = @import("std");

pub const FileChange = struct {
    path: []const u8,
    kind: ChangeKind,
};

pub const ChangeKind = enum {
    created,
    modified,
    deleted,
};
