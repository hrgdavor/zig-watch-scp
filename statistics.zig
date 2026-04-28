// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const builtin = @import("builtin");
const watcher = @import("src/watcher.zig");

const RawEvent = struct {
    timestamp_ms: u64,
    path: []const u8,
    kind: watcher.ChangeKind,
};

const Config = struct {
    watch_path: []const u8,
    scenario: []const u8,
    report_dir: []const u8,
    duration_ms: u64,
    max_events: u64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();

    const args = try init.minimal.args.toSlice(parse_arena.allocator());
    const config = try parseArgs(args);

    try std.Io.Dir.cwd().createDirPath(init.io, config.report_dir);

    var watcher_inst = try watcher.Watcher.init(allocator, init.io, config.watch_path);
    defer watcher_inst.deinit();

    const backend = watcherBackend();
    const platform = platformName();
    const tool_version = try zigVersion(allocator);

    const report_timestamp = std.Io.Timestamp.now(init.io, .real);
    const report_ms: u64 = @intCast(@divTrunc(report_timestamp.nanoseconds, std.time.ns_per_ms));
    const run_id = try formatRunId(allocator, report_ms);

    var raw_events = std.ArrayList(RawEvent).empty;
    defer {
        for (raw_events.items) |event| allocator.free(event.path);
        raw_events.deinit(allocator);
    }

    var per_file_counts = std.StringHashMap(u64).init(allocator);
    defer per_file_counts.deinit();

    var total_events: u64 = 0;
    var duplicate_event_count: u64 = 0;
    var burst_start_ms: ?u64 = null;
    var burst_end_ms: ?u64 = null;
    var last_event_path: []const u8 = "";
    var last_event_kind: watcher.ChangeKind = .created;
    var last_event_timestamp_ms: u64 = 0;
    var have_last_event = false;

    var stop_at: ?u64 = null;
    if (config.duration_ms != 0) {
        const add_result = @addWithOverflow(report_ms, config.duration_ms);
        if (add_result[1] != 0) {
            stop_at = null;
        } else {
            stop_at = add_result[0];
        }
    }

    std.debug.print("Collecting filesystem watcher statistics for {s} in {s}...\n", .{ config.watch_path, config.report_dir });

    while (true) {
        const now = std.Io.Timestamp.now(init.io, .real);
        const now_ms: u64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));

        if (stop_at) |limit| {
            if (now_ms >= limit) break;
        }
        if (config.max_events != 0 and total_events >= config.max_events) break;

        watcher_inst.wait(250) catch |err| {
            std.debug.print("Watcher wait error: {s}\n", .{@errorName(err)});
            continue;
        };

        const maybe_event = watcher_inst.nextEvent() catch |err| {
            std.debug.print("Watcher nextEvent error: {s}\n", .{@errorName(err)});
            continue;
        };
        if (maybe_event == null) continue;
        const event = maybe_event.?;

        const elapsed_ms = now_ms;
        const event_path = try allocator.dupe(u8, event.path);

        try updatePerFileCounts(&per_file_counts, event_path);
        total_events += 1;

        if (!have_last_event) {
            burst_start_ms = elapsed_ms;
            have_last_event = true;
        } else if (last_event_path.len != 0 and std.mem.eql(u8, last_event_path, event_path) and event.kind == last_event_kind and elapsed_ms - last_event_timestamp_ms <= 500) {
            duplicate_event_count += 1;
        }

        burst_end_ms = elapsed_ms;
        last_event_path = event_path;
        last_event_kind = event.kind;
        last_event_timestamp_ms = elapsed_ms;

        try raw_events.append(allocator, RawEvent{ .timestamp_ms = elapsed_ms, .path = event_path, .kind = event.kind });
    }

    const unique_files = per_file_counts.count();
    const avg_events_per_file: f64 = if (unique_files == 0) 0.0 else @as(f64, @floatFromInt(total_events)) / @as(f64, @floatFromInt(@as(u64, unique_files)));
    const session_end_ms = if (burst_end_ms) |v| v else report_ms;
    const session_start_ms = if (burst_start_ms) |v| v else report_ms;
    const burst_duration_ms = if (burst_start_ms) |start| if (burst_end_ms) |end| end - start else 0 else 0;

    const anomalies = gatherAnomalies(total_events, duplicate_event_count);
    const sanitize_scenario = try sanitizeLabel(allocator, config.scenario);
    const report_file_name = try formatReportFileName(allocator, sanitize_scenario, report_ms);
    const report_path = try std.fs.path.join(allocator, &[_][]const u8{ config.report_dir, report_file_name });
    defer allocator.free(report_path);

    const report_file = try std.Io.Dir.cwd().createFile(init.io, report_path, .{ .truncate = true });
    defer report_file.close(init.io);
    var file_buffer: [16384]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(report_file, init.io, &file_buffer);
    const out = &file_writer.interface;

    try writeReport(out, .{
        .run_id = run_id,
        .watch_path = config.watch_path,
        .scenario = config.scenario,
        .report_dir = config.report_dir,
        .platform = platform,
        .backend = backend,
        .tool_version = tool_version,
        .duration_ms = config.duration_ms,
        .total_events = total_events,
        .files_changed = unique_files,
        .avg_events_per_file = avg_events_per_file,
        .duplicate_event_count = duplicate_event_count,
        .burst_duration_ms = burst_duration_ms,
        .session_start_ms = session_start_ms,
        .session_end_ms = session_end_ms,
        .anomalies = anomalies,
        .raw_events = raw_events.items,
        .per_file_counts = &per_file_counts,
    });

    try out.flush();
    std.debug.print("Written statistics report: {s}\n", .{report_path});
}

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{
        .watch_path = ".",
        .scenario = "manual",
        .report_dir = "stats-reports",
        .duration_ms = 30_000,
        .max_events = 0,
    };

    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--path") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            config.watch_path = args[i];
        } else if (std.mem.eql(u8, arg, "--scenario") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            config.scenario = args[i];
        } else if (std.mem.eql(u8, arg, "--report-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            config.report_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--duration") or std.mem.eql(u8, arg, "-d")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            config.duration_ms = try parseDuration(args[i]);
        } else if (std.mem.eql(u8, arg, "--max-events")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            config.max_events = try std.fmt.parseInt(u64, args[i], 10);
        } else {
            return error.UnknownArgument;
        }
        i += 1;
    }
    return config;
}

fn printUsage() void {
    std.debug.print("Usage: statistics [options]\n  --path, -p <dir>          Directory to watch (default: .)\n  --scenario, -s <name>     Scenario tag for report output (default: manual)\n  --report-dir <dir>        Output directory for reports (default: stats-reports)\n  --duration, -d <ms>       Watch duration in milliseconds (default: 30000, 0 = indefinite)\n  --max-events <n>          Stop after at most n events (default: 0 = unlimited)\n  --help, -h                Show this help message\n", .{});
}

fn parseDuration(value: []const u8) !u64 {
    const duration = try std.fmt.parseInt(u64, value, 10);
    return duration;
}

fn watcherBackend() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "inotify",
        .macos => "fsevents",
        .windows => "ReadDirectoryChangesW",
        else => "unknown",
    };
}

fn platformName() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => "unknown",
    };
}

fn zigVersion(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [64]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "zig {d}.{d}.{d}", .{ builtin.zig_version.major, builtin.zig_version.minor, builtin.zig_version.patch });
    return try allocator.dupe(u8, str);
}

fn formatRunId(allocator: std.mem.Allocator, timestamp_ms: u64) ![]const u8 {
    var buf: [64]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "stats-{d}", .{timestamp_ms});
    return try allocator.dupe(u8, str);
}

fn formatReportFileName(allocator: std.mem.Allocator, scenario: []const u8, timestamp_ms: u64) ![]const u8 {
    var buf: [128]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "stats-{s}-{d}.json", .{ scenario, timestamp_ms });
    return try allocator.dupe(u8, str);
}

fn sanitizeLabel(allocator: std.mem.Allocator, label: []const u8) ![]const u8 {
    var sanitized = std.ArrayList(u8).empty;

    for (label) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_') {
            try sanitized.append(allocator, c);
        } else {
            try sanitized.append(allocator, '_');
        }
    }

    return try sanitized.toOwnedSlice(allocator);
}

fn gatherAnomalies(total_events: u64, duplicate_event_count: u64) []const []const u8 {
    if (total_events == 0) {
        return &[_][]const u8{"no events detected"};
    }
    if (duplicate_event_count > 0) {
        return &[_][]const u8{"duplicate event bursts detected"};
    }
    return &[_][]const u8{};
}

fn updatePerFileCounts(map: *std.StringHashMap(u64), path: []const u8) !void {
    if (map.get(path)) |value| {
        try map.put(path, value + 1);
    } else {
        try map.put(path, 1);
    }
}

fn kindToString(kind: watcher.ChangeKind) []const u8 {
    return switch (kind) {
        .created => "created",
        .modified => "modified",
        .deleted => "deleted",
    };
}

fn writeReport(writer: anytype, report: struct {
    run_id: []const u8,
    watch_path: []const u8,
    scenario: []const u8,
    report_dir: []const u8,
    platform: []const u8,
    backend: []const u8,
    tool_version: []const u8,
    duration_ms: u64,
    total_events: u64,
    files_changed: usize,
    avg_events_per_file: f64,
    duplicate_event_count: u64,
    burst_duration_ms: u64,
    session_start_ms: u64,
    session_end_ms: u64,
    anomalies: []const []const u8,
    raw_events: []const RawEvent,
    per_file_counts: *const std.StringHashMap(u64),
}) !void {
    try writer.print("{{\n", .{});
    try writeJsonString(writer, "run_id", report.run_id, true);
    try writeJsonString(writer, "watch_path", report.watch_path, true);
    try writeJsonString(writer, "scenario", report.scenario, true);
    try writeJsonString(writer, "report_dir", report.report_dir, true);
    try writeJsonString(writer, "platform", report.platform, true);
    try writeJsonString(writer, "backend", report.backend, true);
    try writeJsonString(writer, "tool_version", report.tool_version, true);
    try writeJsonNumber(writer, "duration_ms", report.duration_ms, true);
    try writeJsonNumber(writer, "total_events", report.total_events, true);
    try writeJsonNumber(writer, "files_changed", @as(u64, report.files_changed), true);
    try writeJsonFloat(writer, "avg_events_per_file", report.avg_events_per_file, true);
    try writeJsonNumber(writer, "duplicate_event_count", report.duplicate_event_count, true);
    try writeJsonNumber(writer, "burst_duration_ms", report.burst_duration_ms, true);
    try writeJsonNumber(writer, "session_start_ms", report.session_start_ms, true);
    try writeJsonNumber(writer, "session_end_ms", report.session_end_ms, false);

    try writer.print("  \"anomalies\": [", .{});
    var first = true;
    for (report.anomalies) |anomaly| {
        if (!first) try writer.print(", ", .{});
        try writeEscapedString(writer, anomaly);
        first = false;
    }
    try writer.print("],\n", .{});

    try writer.print("  \"raw_events\": [\n", .{});
    var idx: usize = 0;
    while (idx < report.raw_events.len) {
        const event = report.raw_events[idx];
        try writer.print("    {{\n", .{});
        try writeJsonNumber(writer, "timestamp_ms", event.timestamp_ms, true);
        try writeJsonString(writer, "path", event.path, true);
        try writeJsonString(writer, "kind", kindToString(event.kind), false);
        try writer.print("    }}{s}\n", .{if (idx + 1 < report.raw_events.len) "," else ""});
        idx += 1;
    }
    try writer.print("  ],\n", .{});

    try writer.print("  \"per_file_counts\": {{\n", .{});
    var iter = report.per_file_counts.iterator();
    var first_count = true;
    while (iter.next()) |entry| {
        if (!first_count) try writer.print(",\n", .{});
        try writer.print("    \"{s}\": {d}", .{ entry.key_ptr.*, entry.value_ptr.* });
        first_count = false;
    }
    if (!first_count) try writer.print("\n", .{});
    try writer.print("  }}\n", .{});

    try writer.print("}}\n", .{});
}

fn writeJsonString(writer: anytype, key: []const u8, value: []const u8, comma: bool) !void {
    try writer.print("  \"{s}\": \"", .{key});
    try writeEscapedString(writer, value);
    try writer.print("\"{s}\n", .{if (comma) "," else ""});
}

fn writeJsonNumber(writer: anytype, key: []const u8, value: u64, comma: bool) !void {
    try writer.print("  \"{s}\": {d}{s}\n", .{ key, value, if (comma) "," else "" });
}

fn writeJsonFloat(writer: anytype, key: []const u8, value: f64, comma: bool) !void {
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{:.6}", .{value});
    try writer.print("  \"{s}\": {s}{s}\n", .{ key, text, if (comma) "," else "" });
}

fn writeEscapedString(writer: anytype, value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '"' => try writer.print("\\\"", .{}),
            '\\' => try writer.print("\\\\", .{}),
            '\x08' => try writer.print("\\b", .{}),
            '\x0c' => try writer.print("\\f", .{}),
            '\n' => try writer.print("\\n", .{}),
            '\r' => try writer.print("\\r", .{}),
            '\t' => try writer.print("\\t", .{}),
            else => {
                if (c < 0x20) {
                    const byte: u8 = @as(u8, c);
                    const hi = @as(u8, (byte >> 4) & 0xF);
                    const lo = @as(u8, byte & 0xF);
                    var hex: [2]u8 = undefined;
                    hex[0] = if (hi < 10) '0' + hi else 'a' + (hi - 10);
                    hex[1] = if (lo < 10) '0' + lo else 'a' + (lo - 10);
                    try writer.print("\\u00{s}", .{hex[0..2]});
                } else {
                    const byte: u8 = @as(u8, c);
                    _ = try writer.write(&[_]u8{byte});
                }
            },
        }
    }
}
