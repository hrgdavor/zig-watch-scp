// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const scanner = @import("scanner.zig");

// Helper to expose private functions for testing
const Scanner = scanner.Scanner;

test "glob: basic exact match" {
    try std.testing.expect(Scanner.matchPattern("foo.txt", "foo.txt"));
    try std.testing.expect(!Scanner.matchPattern("foo.txt", "bar.txt"));
}

test "glob: single wildcard *" {
    try std.testing.expect(Scanner.matchPattern("foo.txt", "*.txt"));
    try std.testing.expect(Scanner.matchPattern("foo.txt", "f*t"));
    try std.testing.expect(Scanner.matchPattern("foo.txt", "*"));
    try std.testing.expect(!Scanner.matchPattern("dir/foo.txt", "*.txt")); // * doesn't match /
}

test "glob: single wildcard ?" {
    try std.testing.expect(Scanner.matchPattern("foo.txt", "fo?.txt"));
    try std.testing.expect(!Scanner.matchPattern("foo.txt", "f?.txt"));
}

test "glob: recursive wildcard **" {
    try std.testing.expect(Scanner.matchPattern("foo.txt", "**/foo.txt"));
    try std.testing.expect(Scanner.matchPattern("dir/foo.txt", "**/foo.txt"));
    try std.testing.expect(Scanner.matchPattern("a/b/c/foo.txt", "**/foo.txt"));
    try std.testing.expect(Scanner.matchPattern("a/b/c/foo.txt", "a/**/foo.txt"));
    try std.testing.expect(Scanner.matchPattern("a/b/c/foo.txt", "a/b/**"));
    try std.testing.expect(Scanner.matchPattern("a/b/c/foo.txt", "**"));
    try std.testing.expect(!Scanner.matchPattern("a/b/c/foo.txt", "b/**"));
}

test "glob: mixed wildcards" {
    try std.testing.expect(Scanner.matchPattern("src/components/button.zig", "src/**/*.zig"));
    try std.testing.expect(Scanner.matchPattern("src/main.zig", "src/**/*.zig"));
    try std.testing.expect(!Scanner.matchPattern("tests/main.zig", "src/**/*.zig"));
}

test "glob: path separators" {
    try std.testing.expect(Scanner.matchPattern("dir/foo.txt", "dir\\*"));
    try std.testing.expect(Scanner.matchPattern("dir\\foo.txt", "dir/*"));
}
