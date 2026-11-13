// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const config = @import("config.zig");
const Config = config.Config;

test "config: parse text_extensions, include, and exclude" {
    const allocator = std.testing.allocator;

    // Create a dummy config file
    const file_content =
        \\[folder]
        \\scpdb = test.scpdb
        \\local_dir = ./local
        \\remote_dir = /remote
        \\text_extensions = .zig, .c, .h
        \\include = src/**/*.zig, src/**/*.h
        \\exclude = **/node_modules/**, **/*.tmp
        \\
        \\[file]
        \\local_file = ./single.txt
        \\remote_dir = /remote-file
    ;

    const tmp_file_path = "test_sync.conf";
    const io = std.testing.io;

    const file = try std.Io.Dir.cwd().createFile(io, tmp_file_path, .{});
    try file.writeStreamingAll(io, file_content);
    file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_file_path) catch {};

    var cfg = Config{
        .host = try allocator.dupe(u8, "127.0.0.1"),
        .username = try allocator.dupe(u8, "test"),
        .password = try allocator.dupe(u8, ""),
        .key_path = try allocator.dupe(u8, ""),
        .passphrase = try allocator.dupe(u8, ""),
        .parallel_threads = 4,
        .watch_delay_ms = 200,
        .compress = false,
        .simple_log = false,
        .cleanup = false,
        .dry_run = false,
        .watch = false,
        .verbose = false,
        .color = false,
        .file_mode = 0o644,
        .dir_mode = 0o755,
        .version_from = null,
        .version_to = null,
        .version_name = null,
        .text_extensions = try allocator.alloc([]const u8, 0),
        .folders = try allocator.alloc(config.Folder, 0),
        .local_copy_workers = try allocator.alloc(config.LocalCopyWorkerConfig, 0),
        .exec_cmd = null,
        .create_folder = null,
        .create_includes = try allocator.alloc([]const u8, 0),
        .create_excludes = try allocator.alloc([]const u8, 0),
        .get_file = null,
        .put_file = null,
    };
    defer {
        allocator.free(cfg.host);
        allocator.free(cfg.username);
        allocator.free(cfg.password);
        allocator.free(cfg.key_path);
        allocator.free(cfg.passphrase);
        for (cfg.text_extensions) |ext| allocator.free(ext);
        allocator.free(cfg.text_extensions);
        for (cfg.folders) |f| {
            allocator.free(f.scpdb);
            allocator.free(f.local_dir);
            allocator.free(f.remote_dir);
            for (f.include_patterns) |p| allocator.free(p);
            allocator.free(f.include_patterns);
            for (f.exclude_patterns) |p| allocator.free(p);
            allocator.free(f.exclude_patterns);
        }
        allocator.free(cfg.folders);
        for (cfg.local_copy_workers) |w| {
            allocator.free(w.dest_dir);
            for (w.sources) |s| {
                allocator.free(s.local_dir);
                for (s.include_patterns) |p| allocator.free(p);
                allocator.free(s.include_patterns);
                for (s.exclude_patterns) |p| allocator.free(p);
                allocator.free(s.exclude_patterns);
            }
            allocator.free(w.sources);
        }
        allocator.free(cfg.local_copy_workers);
        for (cfg.create_includes) |p| allocator.free(p);
        allocator.free(cfg.create_includes);
        for (cfg.create_excludes) |p| allocator.free(p);
        allocator.free(cfg.create_excludes);
    }

    var cli_vars = std.StringHashMap([]const u8).init(allocator);
    defer cli_vars.deinit();

    try config.Config.parseIntoConfig(allocator, io, std.testing.environ, cli_vars, &cfg, tmp_file_path);

    // Verify text_extensions
    try std.testing.expectEqual(@as(usize, 3), cfg.text_extensions.len);
    try std.testing.expectEqualStrings(".zig", cfg.text_extensions[0]);

    // Verify folders
    try std.testing.expectEqual(@as(usize, 2), cfg.folders.len);
    try std.testing.expectEqualStrings("./local", cfg.folders[0].local_dir);
    try std.testing.expectEqualStrings("/remote", cfg.folders[0].remote_dir);

    // Verify [file] shorthand
    try std.testing.expect(cfg.folders[1].single_file);
    try std.testing.expect(cfg.folders[1].no_db);
    try std.testing.expectEqual(config.CheckMode.mtime_size, cfg.folders[1].check);
    try std.testing.expectEqual(@as(usize, 1), cfg.folders[1].include_patterns.len);
    try std.testing.expectEqualStrings("single.txt", cfg.folders[1].include_patterns[0]);
    try std.testing.expectEqualStrings("/remote-file", cfg.folders[1].remote_dir);
}

test "ssh_config: resolution" {
    const allocator = std.testing.allocator;

    const ssh_config_content =
        \\Host myalias
        \\    HostName 1.2.3.4
        \\    User myuser
        \\    Port 2222
        \\    IdentityFile ~/.ssh/id_rsa_test
    ;

    const tmp_ssh_path = "test_ssh_config";
    const io = std.testing.io;

    const file = try std.Io.Dir.cwd().createFile(io, tmp_ssh_path, .{});
    try file.writeStreamingAll(io, ssh_config_content);
    file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_ssh_path) catch {};

    var cfg = Config{
        .host = try allocator.dupe(u8, "myalias"),
        .username = try allocator.dupe(u8, ""),
        .password = try allocator.dupe(u8, ""),
        .key_path = try allocator.dupe(u8, ""),
        .passphrase = try allocator.dupe(u8, ""),
        .parallel_threads = 4,
        .watch_delay_ms = 200,
        .compress = false,
        .simple_log = false,
        .cleanup = false,
        .dry_run = false,
        .watch = false,
        .verbose = false,
        .color = false,
        .file_mode = 0o644,
        .dir_mode = 0o755,
        .version_from = null,
        .version_to = null,
        .version_name = null,
        .text_extensions = try allocator.alloc([]const u8, 0),
        .folders = try allocator.alloc(config.Folder, 0),
        .local_copy_workers = try allocator.alloc(config.LocalCopyWorkerConfig, 0),
        .exec_cmd = null,
        .create_folder = null,
        .create_includes = try allocator.alloc([]const u8, 0),
        .create_excludes = try allocator.alloc([]const u8, 0),
        .get_file = null,
        .put_file = null,
    };
    defer {
        allocator.free(cfg.host);
        allocator.free(cfg.username);
        allocator.free(cfg.password);
        allocator.free(cfg.key_path);
        allocator.free(cfg.passphrase);
        allocator.free(cfg.text_extensions);
        allocator.free(cfg.folders);
        allocator.free(cfg.local_copy_workers);
        allocator.free(cfg.create_includes);
        allocator.free(cfg.create_excludes);
    }

    const abs_path = try std.Io.Dir.cwd().realPathFileAlloc(io, tmp_ssh_path, allocator);
    defer allocator.free(abs_path);

    try config.Config.resolveSshConfigFile(allocator, io, std.testing.environ, &cfg, abs_path);

    try std.testing.expectEqualStrings("1.2.3.4:2222", cfg.host);
    try std.testing.expectEqualStrings("myuser", cfg.username);
    // IdentityFile should be expanded to an absolute path under the current user's home.
    try std.testing.expect(std.mem.indexOf(u8, cfg.key_path, "id_rsa_test") != null);
    try std.testing.expect(std.fs.path.isAbsolute(cfg.key_path));
}

