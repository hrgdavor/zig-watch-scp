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

fn baseConfig(allocator: std.mem.Allocator) !Config {
    return Config{
        .host = try allocator.dupe(u8, ""),
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
}

/// Parse `content` as a config file using an arena so the test does not have to
/// mirror the parser's ownership rules.
fn parseConfigFile(arena: std.mem.Allocator, io: std.Io, file_name: []const u8, content: []const u8) !Config {
    return parseConfigFileWithVars(arena, io, file_name, content, std.StringHashMap([]const u8).init(arena));
}

fn parseConfigFileWithVars(
    arena: std.mem.Allocator,
    io: std.Io,
    file_name: []const u8,
    content: []const u8,
    cli_vars: std.StringHashMap([]const u8),
) !Config {
    const file = try std.Io.Dir.cwd().createFile(io, file_name, .{});
    try file.writeStreamingAll(io, content);
    file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, file_name) catch {};

    var cfg = try baseConfig(arena);
    try config.Config.parseIntoConfig(arena, io, std.testing.environ, cli_vars, &cfg, file_name);
    return cfg;
}

test "config: inline variable default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = try parseConfigFile(arena, std.testing.io, "test_var_inline.conf",
        \\[folder]
        \\local_dir = ./src
        \\remote_dir = ${REMOTE_ROOT:-/opt/app}/src
    );

    try std.testing.expectEqualStrings("/opt/app/src", cfg.folders[0].remote_dir);
}

test "config: ENV default beats inline default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = try parseConfigFile(arena, std.testing.io, "test_var_env.conf",
        \\ENV.REMOTE_ROOT=/committed
        \\[folder]
        \\local_dir = ./src
        \\remote_dir = ${REMOTE_ROOT:-/fallback}/src
    );

    try std.testing.expectEqualStrings("/committed/src", cfg.folders[0].remote_dir);
}

test "config: --var beats ENV and inline defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cli_vars = std.StringHashMap([]const u8).init(arena);
    try cli_vars.put("REMOTE_ROOT", "/cli");

    const cfg = try parseConfigFileWithVars(arena, std.testing.io, "test_var_cli.conf",
        \\ENV.REMOTE_ROOT=/committed
        \\[folder]
        \\local_dir = ./src
        \\remote_dir = ${REMOTE_ROOT:-/fallback}/src
    , cli_vars);

    try std.testing.expectEqualStrings("/cli/src", cfg.folders[0].remote_dir);
}

test "config: nested inline defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = try parseConfigFile(arena, std.testing.io, "test_var_nested.conf",
        \\[folder]
        \\local_dir = ./src
        \\remote_dir = ${A:-${B:-/nested}}/src
    );

    try std.testing.expectEqualStrings("/nested/src", cfg.folders[0].remote_dir);
}

test "config: empty variable falls back to inline default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = try parseConfigFile(arena, std.testing.io, "test_var_empty_default.conf",
        \\ENV.REMOTE_ROOT=
        \\[folder]
        \\local_dir = ./src
        \\remote_dir = ${REMOTE_ROOT:-/fallback}/src
    );

    try std.testing.expectEqualStrings("/fallback/src", cfg.folders[0].remote_dir);
}

test "config: empty variable without default is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.EmptyConfigVariable, parseConfigFile(arena, std.testing.io, "test_var_empty.conf",
        \\ENV.REMOTE_ROOT=
        \\[folder]
        \\local_dir = ./src
        \\remote_dir = ${REMOTE_ROOT}/src
    ));
}

test "config: undefined variable without default is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.UndefinedConfigVariable, parseConfigFile(arena, std.testing.io, "test_var_missing.conf",
        \\[folder]
        \\local_dir = ./src
        \\remote_dir = ${MISSING_ROOT}/src
    ));
}

test "config: empty variable name is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.InvalidVariableName, parseConfigFile(arena, std.testing.io, "test_var_badname.conf",
        \\[folder]
        \\local_dir = ./src
        \\remote_dir = ${:-/fallback}/src
    ));
}

test "config: variables expand in global values and a lone '$' survives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = try parseConfigFile(arena, std.testing.io, "test_var_global.conf",
        \\host = ${DEV_HOST:-dev.example.com}
        \\[folder]
        \\local_dir = ./src
        \\remote_dir = /opt/a$b
    );

    try std.testing.expectEqualStrings("dev.example.com", cfg.host);
    try std.testing.expectEqualStrings("/opt/a$b", cfg.folders[0].remote_dir);
}

test "config: --var rejects names containing PASSWORD or PASSPHRASE" {
    try std.testing.expectError(error.ForbiddenVariableName, config.Config.validateVarName("MY_PASSWORD"));
    try std.testing.expectError(error.ForbiddenVariableName, config.Config.validateVarName("my_password"));
    try std.testing.expectError(error.ForbiddenVariableName, config.Config.validateVarName("PASSWORD_FILE"));
    try std.testing.expectError(error.ForbiddenVariableName, config.Config.validateVarName("KEY_PASSPHRASE"));
    // Environment variables are still allowed; only --var is restricted.
    try config.Config.validateVarName("REMOTE_ROOT");
    try config.Config.validateVarName("DEV_HOST");
}

test "config: secret files are read as a single line" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try std.Io.Dir.cwd().createDirPath(io, "test_secrets");
    defer std.Io.Dir.cwd().deleteTree(io, "test_secrets") catch {};

    const Fixture = struct { name: []const u8, content: []const u8, expected: []const u8 };
    const fixtures = [_]Fixture{
        .{ .name = "test_secrets/plain", .content = "s3cret", .expected = "s3cret" },
        .{ .name = "test_secrets/lf", .content = "s3cret\n", .expected = "s3cret" },
        .{ .name = "test_secrets/crlf", .content = "s3cret\r\n", .expected = "s3cret" },
        .{ .name = "test_secrets/spaces", .content = "  two words  \n", .expected = "  two words  " },
    };
    for (fixtures) |fixture| {
        const file = try std.Io.Dir.cwd().createFile(io, fixture.name, .{});
        try file.writeStreamingAll(io, fixture.content);
        file.close(io);

        const secret = try config.Config.readSecretFile(allocator, io, std.testing.environ, fixture.name, "password");
        defer allocator.free(secret);
        try std.testing.expectEqualStrings(fixture.expected, secret);
    }
}

test "config: invalid secret files are rejected" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try std.Io.Dir.cwd().createDirPath(io, "test_secrets_bad");
    defer std.Io.Dir.cwd().deleteTree(io, "test_secrets_bad") catch {};

    const empty_file = try std.Io.Dir.cwd().createFile(io, "test_secrets_bad/empty", .{});
    empty_file.close(io);

    const multi_file = try std.Io.Dir.cwd().createFile(io, "test_secrets_bad/multi", .{});
    try multi_file.writeStreamingAll(io, "one\ntwo\n");
    multi_file.close(io);

    try std.testing.expectError(error.SecretFileInvalid, config.Config.readSecretFile(allocator, io, std.testing.environ, "test_secrets_bad/empty", "password"));
    try std.testing.expectError(error.SecretFileInvalid, config.Config.readSecretFile(allocator, io, std.testing.environ, "test_secrets_bad/multi", "password"));
    try std.testing.expectError(error.SecretFileUnreadable, config.Config.readSecretFile(allocator, io, std.testing.environ, "test_secrets_bad/missing", "password"));
}

test "config: password source precedence" {
    const io = std.testing.io;
    // resolveSecret may return a borrowed slice (environment/config value) or a
    // freshly allocated one (secret file), so the test owns an arena instead of
    // freeing individual results.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    try std.Io.Dir.cwd().createDirPath(io, "test_secret_prec");
    defer std.Io.Dir.cwd().deleteTree(io, "test_secret_prec") catch {};

    const file = try std.Io.Dir.cwd().createFile(io, "test_secret_prec/secret", .{});
    try file.writeStreamingAll(io, "from-file\n");
    file.close(io);

    const none = config.Config.SecretSource{
        .cli_file = null,
        .cli_value = null,
        .env_file_name = "SYNC_TEST_NO_SUCH_FILE_VAR",
        .env_value_name = "SYNC_TEST_NO_SUCH_VALUE_VAR",
        .config_file = null,
        .config_value = "from-config",
        .what = "password",
    };

    try std.testing.expectEqualStrings("from-config", try config.Config.resolveSecret(allocator, io, std.testing.environ, none));

    var with_file = none;
    with_file.config_file = "test_secret_prec/secret";
    try std.testing.expectEqualStrings("from-file", try config.Config.resolveSecret(allocator, io, std.testing.environ, with_file));

    var with_cli = with_file;
    with_cli.cli_value = "from-cli";
    try std.testing.expectEqualStrings("from-cli", try config.Config.resolveSecret(allocator, io, std.testing.environ, with_cli));

    with_cli.cli_file = "test_secret_prec/secret";
    try std.testing.expectEqualStrings("from-file", try config.Config.resolveSecret(allocator, io, std.testing.environ, with_cli));
}

test "config: password_file and passphrase_file are parsed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = try parseConfigFile(arena, std.testing.io, "test_secret_paths.conf",
        \\password_file = /run/secrets/sync_password
        \\passphrase_file = /run/secrets/sync_passphrase
        \\[folder]
        \\local_dir = ./src
        \\remote_dir = /srv/src
    );

    try std.testing.expectEqualStrings("/run/secrets/sync_password", cfg.password_file.?);
    try std.testing.expectEqualStrings("/run/secrets/sync_passphrase", cfg.passphrase_file.?);
}

test "config: each folder keeps its own scpdb" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = try parseConfigFile(arena, std.testing.io, "test_multi_scpdb.conf",
        \\[folder]
        \\local_dir = ./one
        \\remote_dir = /srv/one
        \\scpdb = .scpdb.one
        \\local_db = true
        \\
        \\[folder]
        \\local_dir = ./two
        \\remote_dir = /srv/two
        \\
        \\[file]
        \\local_file = ./three.txt
        \\remote_dir = /srv/three.txt
        \\
        \\[folder]
        \\local_dir = ./four
        \\remote_dir = /srv/four
    );

    try std.testing.expectEqual(@as(usize, 4), cfg.folders.len);
    try std.testing.expectEqualStrings(".scpdb.one", cfg.folders[0].scpdb);
    try std.testing.expect(cfg.folders[0].local_db);
    // Folder 2 must not inherit folder 1's custom database.
    try std.testing.expectEqualStrings(".scpdb", cfg.folders[1].scpdb);
    try std.testing.expect(!cfg.folders[1].local_db);
    // [file] sections are database-less; the following folder gets the default.
    try std.testing.expect(cfg.folders[2].no_db);
    try std.testing.expectEqualStrings(".scpdb", cfg.folders[3].scpdb);
}

test "config: incomplete [folder] section is reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.IncompleteFolderSection, parseConfigFile(arena, std.testing.io, "test_incomplete_folder.conf",
        \\[folder]
        \\local_dir = ./one
        \\remote_dir = /srv/one
        \\
        \\[folder]
        \\scpdb = .scpdb.two
        \\local_db = true
    ));
}

test "config: UTF-8 BOM does not hide the first folder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = try parseConfigFile(arena, std.testing.io, "test_bom.conf", "\xEF\xBB\xBFhost = 1.2.3.4\n" ++
        "[folder]\nlocal_dir = ./src\nremote_dir = /srv/src\n");

    try std.testing.expectEqual(@as(usize, 1), cfg.folders.len);
    try std.testing.expectEqualStrings("./src", cfg.folders[0].local_dir);
}

test "config: global scpdb is ignored per folder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = try parseConfigFile(arena, std.testing.io, "test_global_scpdb.conf",
        \\scpdb = D:/meta/global.scpdb
        \\[folder]
        \\local_dir = ./a
        \\remote_dir = /srv/a
        \\[folder]
        \\local_dir = ./b
        \\remote_dir = /srv/b
    );

    try std.testing.expectEqual(@as(usize, 2), cfg.folders.len);
    try std.testing.expectEqualStrings(".scpdb", cfg.folders[0].scpdb);
    try std.testing.expectEqualStrings(".scpdb", cfg.folders[1].scpdb);
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
