// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");

/// ANSI terminal color and style codes.
///
/// Use `Color.escape(color)` to get the raw escape sequence string.
/// For structured printing with optional color support, use `Printer`.
pub const Color = enum {
    reset,
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
    bold,
    dim,
    underline,

    /// Returns the ANSI escape sequence for this color/style.
    /// Usable at runtime (e.g. writing escape codes to a buffer)
    /// and at comptime (e.g. concatenating into format strings via `Printer.printc`).
    pub fn escape(self: Color) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .black => "\x1b[30m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
            .bright_black => "\x1b[90m",
            .bright_red => "\x1b[91m",
            .bright_green => "\x1b[92m",
            .bright_yellow => "\x1b[93m",
            .bright_blue => "\x1b[94m",
            .bright_magenta => "\x1b[95m",
            .bright_cyan => "\x1b[96m",
            .bright_white => "\x1b[97m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .underline => "\x1b[4m",
        };
    }
};

/// A lightweight stderr printer with optional ANSI color support.
///
/// When `color_enabled` is false all escape codes are omitted, making
/// output safe for piped/redirected streams.
///
/// All code that wants colored output must accept a `Printer` as a
/// parameter and print through it, rather than embedding color constants.
///
/// Example:
///   printer.printc(.yellow, "Synced: {s}\n", .{path});
pub const Printer = struct {
    color_enabled: bool,

    /// Print a plain message with no color.
    pub fn print(_: Printer, comptime fmt: []const u8, args: anytype) void {
        std.debug.print(fmt, args);
    }

    /// Print a message wrapped in the given color/style.
    /// `color` must be comptime so the escape sequences are baked into
    /// the format string at compile time. Falls back to plain output
    /// when `color_enabled` is false.
    pub fn printc(self: Printer, comptime color: Color, comptime fmt: []const u8, args: anytype) void {
        if (self.color_enabled) {
            std.debug.print(comptime (color.escape() ++ fmt ++ Color.escape(.reset)), args);
        } else {
            std.debug.print(fmt, args);
        }
    }
};
