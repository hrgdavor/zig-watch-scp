// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const simargs = @import("simargs");

pub const Folder = struct {
    scpdb: []const u8,
    local_db: bool,
    local_dir: []const u8,
    remote_dir: []const u8,
    include_patterns: []const []const u8,
    exclude_patterns: []const []const u8,
};

pub const LocalSource = struct {
    local_dir: []const u8,
    include_patterns: []const []const u8,
    exclude_patterns: []const []const u8,
};

pub const LocalCopyWorkerConfig = struct {
    dest_dir: []const u8,
    sources: []LocalSource,
};

pub const Config = struct {
    host: []const u8,
    username: []const u8,
    password: []const u8,
    key_path: []const u8,
    passphrase: []const u8,
    parallel_threads: usize,
    watch_delay_ms: u64,
    compress: bool,
    simple_log: bool,
    cleanup: bool,
    text_extensions: []const []const u8,
    folders: []Folder,
    local_copy_workers: []LocalCopyWorkerConfig,
    exec_cmd: ?[]const u8,

    // Standalone create mode
    create_folder: ?[]const u8,
    create_includes: []const []const u8,
    create_excludes: []const []const u8,

    // Standalone get/put mode
    get_file: ?[2][]const u8,
    put_file: ?[2][]const u8,

    // ─────────────────────────────────────────────────────────────────────────
    // simargs struct types
    // ─────────────────────────────────────────────────────────────────────────

    /// Used when a subcommand (get/put/create) is present on the command line.
    const SubArgs = struct {
        config: ?[]const u8 = null,
        compress: bool = false,
        @"simple-log": bool = false,
        cleanup: bool = false,
        @"watch-delay": ?u64 = null,
        exec: ?[]const u8 = null,
        help: bool = false,

        __commands__: union(enum) {
            get: struct {
                help: bool = false,

                pub const __shorts__ = .{ .help = .h };
                pub const __messages__ = .{ .help = "Show this help message" };
            },
            put: struct {
                help: bool = false,

                pub const __shorts__ = .{ .help = .h };
                pub const __messages__ = .{ .help = "Show this help message" };
            },
            create: struct {
                includes: ?[]const u8 = null,
                excludes: ?[]const u8 = null,
                help: bool = false,

                pub const __shorts__ = .{ .help = .h };
                pub const __messages__ = .{
                    .includes = "Comma-separated list of include patterns",
                    .excludes = "Comma-separated list of exclude patterns",
                    .help = "Show this help message",
                };
            },

            pub const __messages__ = .{
                .get = "Download a single file: get <remote-path> <local-path>",
                .put = "Upload a single file:   put <local-path>  <remote-path>",
                .create = "Create .scpdb for a local folder: create <folder-path>",
            };
        },

        pub const __shorts__ = .{
            .config = .c,
            .compress = .x,
            .help = .h,
        };

        pub const __messages__ = .{
            .config = "Path to configuration file",
            .compress = "Enable SSH compression",
            .@"simple-log" = "Use simple logging (no escape codes for progress)",
            .cleanup = "Remove remote files not present locally",
            .@"watch-delay" = "Delay before syncing after change (default: 200 ms)",
            .exec = "Command to execute on remote after sync",
            .help = "Show this help message",
        };
    };

    /// Used in sync mode (no subcommand).  Positional args: [host] [username] [password].
    const SyncArgs = struct {
        config: ?[]const u8 = null,
        compress: bool = false,
        @"simple-log": bool = false,
        cleanup: bool = false,
        @"watch-delay": ?u64 = null,
        exec: ?[]const u8 = null,
        help: bool = false,

        pub const __shorts__ = .{
            .config = .c,
            .compress = .x,
            .help = .h,
        };

        pub const __messages__ = .{
            .config = "Path to configuration file",
            .compress = "Enable SSH compression",
            .@"simple-log" = "Use simple logging (no escape codes for progress)",
            .cleanup = "Remove remote files not present locally",
            .@"watch-delay" = "Delay before syncing after change (default: 200 ms)",
            .exec = "Command to execute on remote after sync",
            .help = "Show this help message",
        };
    };

    // ─────────────────────────────────────────────────────────────────────────
    // parseArgs
    // ─────────────────────────────────────────────────────────────────────────

    pub fn parseArgs(arena_allocator: std.mem.Allocator) !Config {
        // Strategy: try the full SubArgs parse first.
        //   • If it succeeds               → subcommand mode.
        //   • If error.MissingSubCommand   → sync mode, re-parse with SyncArgs.
        //   • Any other error              → propagate.

        var create_folder: ?[]const u8 = null;
        var create_includes = std.ArrayList([]const u8).empty;
        var create_excludes = std.ArrayList([]const u8).empty;
        var get_file: ?[2][]const u8 = null;
        var put_file: ?[2][]const u8 = null;

        var cli_compress: bool = false;
        var cli_simple_log: bool = false;
        var cli_cleanup: bool = false;
        var cli_watch_delay: ?u64 = null;
        var cli_exec_cmd: ?[]const u8 = null;
        var config_path: ?[]const u8 = null;
        var cli_host: ?[]const u8 = null;
        var cli_username: ?[]const u8 = null;
        var cli_password: ?[]const u8 = null;

        // ── attempt subcommand parse ──────────────────────────────────────────
        const sub_result = simargs.parse(
            arena_allocator,
            SubArgs,
            "[host] [username] [password]",
            "0.0.0",
        ) catch |err| switch (err) {
            error.MissingSubCommand => null, // → sync mode below
            else => return err,
        };

        if (sub_result) |sub_opt| {
            // subcommand mode

            cli_compress = sub_opt.args.compress;
            cli_simple_log = sub_opt.args.@"simple-log";
            cli_cleanup = sub_opt.args.cleanup;
            cli_watch_delay = sub_opt.args.@"watch-delay";
            cli_exec_cmd = sub_opt.args.exec;
            config_path = sub_opt.args.config;

            switch (sub_opt.args.__commands__) {
                .get => {
                    if (sub_opt.positional_args.len < 2) {
                        std.debug.print("Error: 'get' requires <remote-path> <local-path>\n", .{});
                        return error.MissingGetPaths;
                    }
                    get_file = .{ sub_opt.positional_args[0], sub_opt.positional_args[1] };
                },
                .put => {
                    if (sub_opt.positional_args.len < 2) {
                        std.debug.print("Error: 'put' requires <local-path> <remote-path>\n", .{});
                        return error.MissingPutPaths;
                    }
                    put_file = .{ sub_opt.positional_args[0], sub_opt.positional_args[1] };
                },
                .create => |sub| {
                    if (sub_opt.positional_args.len < 1) {
                        std.debug.print("Error: 'create' requires <folder-path>\n", .{});
                        return error.MissingCreatePath;
                    }
                    create_folder = sub_opt.positional_args[0];
                    if (sub.includes) |inc| {
                        var it = std.mem.tokenizeAny(u8, inc, ", \t");
                        while (it.next()) |pat| try create_includes.append(arena_allocator, try arena_allocator.dupe(u8, pat));
                    }
                    if (sub.excludes) |exc| {
                        var it = std.mem.tokenizeAny(u8, exc, ", \t");
                        while (it.next()) |pat| try create_excludes.append(arena_allocator, try arena_allocator.dupe(u8, pat));
                    }
                },
            }
        } else {
            // sync mode (no subcommand)
            const sync_opt = try simargs.parse(
                arena_allocator,
                SyncArgs,
                "[host] [username] [password]",
                "0.0.0",
            );

            cli_compress = sync_opt.args.compress;
            cli_simple_log = sync_opt.args.@"simple-log";
            cli_cleanup = sync_opt.args.cleanup;
            cli_watch_delay = sync_opt.args.@"watch-delay";
            cli_exec_cmd = sync_opt.args.exec;
            config_path = sync_opt.args.config;

            // Positional args: [host] [username] [password]
            if (config_path == null and sync_opt.positional_args.len == 1) {
                config_path = sync_opt.positional_args[0];
            } else {
                if (sync_opt.positional_args.len > 0) cli_host = sync_opt.positional_args[0];
                if (sync_opt.positional_args.len > 1) cli_username = sync_opt.positional_args[1];
                if (sync_opt.positional_args.len > 2) cli_password = sync_opt.positional_args[2];
            }
        }

        // ── validation ────────────────────────────────────────────────────────
        if (config_path == null and create_folder == null and get_file == null and put_file == null) {
            std.debug.print("Error: -c/--config is required for sync mode.\n", .{});
            return error.MissingArguments;
        }

        // ── build Config ──────────────────────────────────────────────────────
        var config = Config{
            .host = if (cli_host) |h| try arena_allocator.dupe(u8, h) else try arena_allocator.dupe(u8, ""),
            .username = if (cli_username) |u| try arena_allocator.dupe(u8, u) else try arena_allocator.dupe(u8, ""),
            .password = if (cli_password) |p| try arena_allocator.dupe(u8, p) else try arena_allocator.dupe(u8, ""),
            .key_path = try arena_allocator.dupe(u8, ""),
            .passphrase = try arena_allocator.dupe(u8, ""),
            .parallel_threads = 4,
            .watch_delay_ms = cli_watch_delay orelse 200,
            .compress = cli_compress,
            .simple_log = cli_simple_log,
            .cleanup = cli_cleanup,
            .exec_cmd = if (cli_exec_cmd) |cmd| try arena_allocator.dupe(u8, cmd) else null,
            .text_extensions = try createDefaultTextExtensions(arena_allocator),
            .folders = try arena_allocator.alloc(Folder, 0),
            .local_copy_workers = try arena_allocator.alloc(LocalCopyWorkerConfig, 0),
            .create_folder = if (create_folder) |f| try arena_allocator.dupe(u8, f) else null,
            .create_includes = try create_includes.toOwnedSlice(arena_allocator),
            .create_excludes = try create_excludes.toOwnedSlice(arena_allocator),
            .get_file = if (get_file) |gf| .{ try arena_allocator.dupe(u8, gf[0]), try arena_allocator.dupe(u8, gf[1]) } else null,
            .put_file = if (put_file) |pf| .{ try arena_allocator.dupe(u8, pf[0]), try arena_allocator.dupe(u8, pf[1]) } else null,
        };

        // Standalone create mode – no SSH config needed
        if (config_path == null and create_folder != null) {
            return config;
        }

        // ── read config file ──────────────────────────────────────────────────
        if (config_path) |cp| {
            const config_file = std.fs.cwd().openFile(cp, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    std.debug.print("Error: Configuration file not found: {s}\n", .{cp});
                }
                return err;
            };
            defer config_file.close();
            try parseIntoConfig(arena_allocator, &config, config_file);
        }

        // Resolve SSH config before environment fallbacks and validation
        try resolveSshConfig(arena_allocator, &config);

        // Environment variable fallbacks for credentials
        if (config.password.len == 0) {
            if (std.process.getEnvVarOwned(arena_allocator, "SYNC_SSH_PWD")) |val| {
                arena_allocator.free(config.password);
                config.password = val;
            } else |_| {}
        }
        if (config.passphrase.len == 0) {
            if (std.process.getEnvVarOwned(arena_allocator, "SYNC_SSH_PASSPHRASE"))|val| {
                arena_allocator.free(config.passphrase);
                config.passphrase = val;
            } else |_| {}
        }

        if (config.host.len == 0 and config.local_copy_workers.len == 0) return error.MissingHost;
        if (config.username.len == 0 and config.local_copy_workers.len == 0) return error.MissingUsername;
        if (config.password.len == 0 and config.key_path.len == 0 and config.local_copy_workers.len == 0) return error.MissingCredentials;

        // Auto-enable simple_log when using multiple threads to avoid output conflicts
        if (config.parallel_threads > 1 and !cli_simple_log) {
            config.simple_log = true;
        }

        return config;
    }

    pub fn resolveSshConfig(allocator: std.mem.Allocator, config: *Config) !void {
        var home_path: ?[]u8 = null;
        if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |val| {
            home_path = val;
        } else |_| {
            if (std.process.getEnvVarOwned(allocator, "HOME")) |val| {
                home_path = val;
            } else |_| {}
        }
        defer if (home_path) |hp| allocator.free(hp);

        if (home_path == null) return;

        const ssh_config_path = try std.fs.path.join(allocator, &.{ home_path.?, ".ssh", "config" });
        defer allocator.free(ssh_config_path);

        try resolveSshConfigFile(allocator, config, ssh_config_path, home_path.?);
    }

    pub fn resolveSshConfigFile(allocator: std.mem.Allocator, config: *Config, path: []const u8, home_path: []const u8) !void {
        if (config.host.len == 0) return;

        const content = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer content.close();

        const config_data = try content.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(config_data);

        var resolved_hostname: ?[]const u8 = null;
        var resolved_port: ?[]const u8 = null;
        var resolved_user: ?[]const u8 = null;
        var resolved_key: ?[]const u8 = null;

        var current_match = false;
        var lines = std.mem.splitScalar(u8, config_data, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            var tokens = std.mem.tokenizeAny(u8, trimmed, " \t");
            const key = tokens.next() orelse continue;

            if (std.ascii.eqlIgnoreCase(key, "Host")) {
                if (current_match) break; // Already found our match and processed its block
                current_match = false;
                while (tokens.next()) |h| {
                    if (std.mem.eql(u8, h, config.host)) {
                        current_match = true;
                        break;
                    }
                }
            } else if (current_match) {
                const value = std.mem.trim(u8, tokens.rest(), " \t\"");
                if (std.ascii.eqlIgnoreCase(key, "HostName")) {
                    resolved_hostname = try allocator.dupe(u8, value);
                } else if (std.ascii.eqlIgnoreCase(key, "User")) {
                    resolved_user = try allocator.dupe(u8, value);
                } else if (std.ascii.eqlIgnoreCase(key, "Port")) {
                    resolved_port = try allocator.dupe(u8, value);
                } else if (std.ascii.eqlIgnoreCase(key, "IdentityFile")) {
                    if (std.mem.startsWith(u8, value, "~")) {
                        const rel_path = std.mem.trimLeft(u8, value[1..], "/\\");
                        resolved_key = try std.fs.path.join(allocator, &.{ home_path, rel_path });
                    } else {
                        resolved_key = try allocator.dupe(u8, value);
                    }
                }
            }
        }

        if (current_match) {
            const has_hostname = resolved_hostname != null;
            const target_host = resolved_hostname orelse config.host;
            if (resolved_port) |p| {
                if (std.mem.indexOf(u8, target_host, ":") == null) {
                    const new_host = try std.fmt.allocPrint(allocator, "{s}:{s}", .{target_host, p});
                    allocator.free(config.host);
                    if (has_hostname) allocator.free(target_host);
                    config.host = new_host;
                    resolved_hostname = null;
                } else if (resolved_hostname) |rh| {
                    allocator.free(config.host);
                    config.host = rh;
                    resolved_hostname = null;
                }
            } else if (resolved_hostname) |rh| {
                allocator.free(config.host);
                config.host = rh;
                resolved_hostname = null;
            }

            if (resolved_user) |u| {
                if (config.username.len == 0) {
                    allocator.free(config.username);
                    config.username = u;
                } else allocator.free(u);
            }
            if (resolved_key) |k| {
                if (config.key_path.len == 0) {
                    allocator.free(config.key_path);
                    config.key_path = k;
                } else allocator.free(k);
            }
            // Cleanup any leftovers if not used
            if (resolved_hostname) |rh| allocator.free(rh);
            if (resolved_port) |rp| allocator.free(rp);
        }
    }


    fn createDefaultTextExtensions(allocator: std.mem.Allocator) ![]const []const u8 {
        const extensions = [_][]const u8{
            ".txt", ".md",  ".c",    ".h",   ".cpp", ".hpp",  ".java", ".py",
            ".js",  ".ts",  ".html", ".css", ".xml", ".json", ".yaml", ".yml",
            ".sh",  ".bat", ".ps1",  ".zig", ".go",  ".rs",   ".rb",   ".php",
        };
        const result = try allocator.alloc([]const u8, extensions.len);
        for (extensions, 0..) |ext, i| {
            result[i] = try allocator.dupe(u8, ext);
        }
        return result;
    }

    pub fn parseIntoConfig(
        allocator: std.mem.Allocator,
        config: *Config,
        file: std.fs.File,
    ) !void {
        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        var folders = std.ArrayList(Folder).empty;
        var local_copy_workers = std.ArrayList(LocalCopyWorkerConfig).empty;

        // Current folder state
        var section: enum { global, folder, local_folder, source } = .global;

        var cur_local_dir: ?[]const u8 = null;
        var cur_scpdb: ?[]const u8 = null;
        var cur_local_db: bool = false;
        var cur_remote_dir: ?[]const u8 = null;
        var cur_includes = std.ArrayList([]const u8).empty;
        var cur_excludes = std.ArrayList([]const u8).empty;

        var cur_dest_dir: ?[]const u8 = null;
        var cur_sources = std.ArrayList(LocalSource).empty;

        const pushFolder = struct {
            fn push(
                alloc: std.mem.Allocator,
                scpdb: *?[]const u8,
                local_db: bool,
                f_list: *std.ArrayList(Folder),
                l_dir: *?[]const u8,
                r_dir: *?[]const u8,
                inc: *std.ArrayList([]const u8),
                exc: *std.ArrayList([]const u8),
            ) !void {
                if (l_dir.* == null and r_dir.* == null and inc.items.len == 0 and exc.items.len == 0) return;
                try f_list.append(alloc, .{
                    .scpdb = scpdb.* orelse try alloc.dupe(u8, ".scpdb"),
                    .local_db = local_db,
                    .local_dir = l_dir.* orelse try alloc.dupe(u8, "."),
                    .remote_dir = r_dir.* orelse try alloc.dupe(u8, "."),
                    .include_patterns = try inc.toOwnedSlice(alloc),
                    .exclude_patterns = try exc.toOwnedSlice(alloc),
                });
                l_dir.* = null;
                r_dir.* = null;
                scpdb.* = null;
            }
        }.push;

        const pushLocalSource = struct {
            fn push(
                alloc: std.mem.Allocator,
                s_list: *std.ArrayList(LocalSource),
                l_dir: *?[]const u8,
                inc: *std.ArrayList([]const u8),
                exc: *std.ArrayList([]const u8),
            ) !void {
                if (l_dir.* == null and inc.items.len == 0 and exc.items.len == 0) return;
                try s_list.append(alloc, .{
                    .local_dir = l_dir.* orelse try alloc.dupe(u8, "."),
                    .include_patterns = try inc.toOwnedSlice(alloc),
                    .exclude_patterns = try exc.toOwnedSlice(alloc),
                });
                l_dir.* = null;
            }
        }.push;

        const pushLocalWorker = struct {
            fn push(
                alloc: std.mem.Allocator,
                w_list: *std.ArrayList(LocalCopyWorkerConfig),
                dest_dir: *?[]const u8,
                s_list: *std.ArrayList(LocalSource),
            ) !void {
                if (dest_dir.* == null and s_list.items.len == 0) return;
                try w_list.append(alloc, .{
                    .dest_dir = dest_dir.* orelse try alloc.dupe(u8, "."),
                    .sources = try s_list.toOwnedSlice(alloc),
                });
                dest_dir.* = null;
            }
        }.push;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.eql(u8, trimmed, "[folder]")) {
                if (section == .folder) try pushFolder(allocator, &cur_scpdb, cur_local_db, &folders, &cur_local_dir, &cur_remote_dir, &cur_includes, &cur_excludes);
                if (section == .source) try pushLocalSource(allocator, &cur_sources, &cur_local_dir, &cur_includes, &cur_excludes);
                if (section == .local_folder) try pushLocalWorker(allocator, &local_copy_workers, &cur_dest_dir, &cur_sources);
                section = .folder;
                cur_local_db = false;
                continue;
            }

            if (std.mem.eql(u8, trimmed, "[local-folder]")) {
                if (section == .folder) try pushFolder(allocator, &cur_scpdb, cur_local_db, &folders, &cur_local_dir, &cur_remote_dir, &cur_includes, &cur_excludes);
                if (section == .source) try pushLocalSource(allocator, &cur_sources, &cur_local_dir, &cur_includes, &cur_excludes);
                if (section == .local_folder) try pushLocalWorker(allocator, &local_copy_workers, &cur_dest_dir, &cur_sources);
                section = .local_folder;
                continue;
            }

            if (std.mem.eql(u8, trimmed, "[source]")) {
                if (section == .folder) try pushFolder(allocator, &cur_scpdb, cur_local_db, &folders, &cur_local_dir, &cur_remote_dir, &cur_includes, &cur_excludes);
                if (section == .source) try pushLocalSource(allocator, &cur_sources, &cur_local_dir, &cur_includes, &cur_excludes);
                section = .source;
                continue;
            }

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], &std.ascii.whitespace);
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace);

                if (std.mem.eql(u8, key, "host") and config.host.len == 0) {
                    config.host = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "username") and config.username.len == 0) {
                    config.username = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "password") and config.password.len == 0) {
                    config.password = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "key_path") and config.key_path.len == 0) {
                    config.key_path = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "passphrase") and config.passphrase.len == 0) {
                    config.passphrase = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "parallel_threads")) {
                    config.parallel_threads = try std.fmt.parseInt(usize, value, 10);
                } else if (std.mem.eql(u8, key, "watch_delay_ms")) {
                    config.watch_delay_ms = try std.fmt.parseInt(u64, value, 10);
                } else if (std.mem.eql(u8, key, "compress")) {
                    config.compress = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "yes");
                } else if (std.mem.eql(u8, key, "cleanup")) {
                    config.cleanup = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "yes");
                } else if (std.mem.eql(u8, key, "exec_cmd") or std.mem.eql(u8, key, "exec")) {
                    config.exec_cmd = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "text_extensions")) {
                    for (config.text_extensions) |ext| allocator.free(ext);
                    allocator.free(config.text_extensions);
                    var ext_list = std.ArrayList([]const u8).empty;
                    var it = std.mem.tokenizeAny(u8, value, ", \t");
                    while (it.next()) |ext| try ext_list.append(allocator, try allocator.dupe(u8, ext));
                    config.text_extensions = try ext_list.toOwnedSlice(allocator);
                } else if (std.mem.eql(u8, key, "local_dir")) {
                    if (section != .folder and section != .source) continue;
                    cur_local_dir = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "remote_dir")) {
                    if (section != .folder) continue;
                    cur_remote_dir = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "dest_dir")) {
                    if (section != .local_folder) continue;
                    cur_dest_dir = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "scpdb")) {
                    if (section != .folder) continue;
                    cur_scpdb = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "include") or std.mem.eql(u8, key, "includes")) {
                    if (section != .folder and section != .source) continue;
                    var it = std.mem.tokenizeAny(u8, value, ", \t");
                    while (it.next()) |pat| try cur_includes.append(allocator, try allocator.dupe(u8, pat));
                } else if (std.mem.eql(u8, key, "exclude") or std.mem.eql(u8, key, "excludes")) {
                    if (section != .folder and section != .source) continue;
                    var it = std.mem.tokenizeAny(u8, value, ", \t");
                    while (it.next()) |pat| try cur_excludes.append(allocator, try allocator.dupe(u8, pat));
                } else if (std.mem.eql(u8, key, "local_db")) {
                    if (section == .folder) {
                        cur_local_db = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "yes");
                    }
                }
            }
        }

        if (section == .folder) try pushFolder(allocator, &cur_scpdb, cur_local_db, &folders, &cur_local_dir, &cur_remote_dir, &cur_includes, &cur_excludes);
        if (section == .source) try pushLocalSource(allocator, &cur_sources, &cur_local_dir, &cur_includes, &cur_excludes);
        if (section == .local_folder or section == .source) try pushLocalWorker(allocator, &local_copy_workers, &cur_dest_dir, &cur_sources);

        if (folders.items.len == 0 and local_copy_workers.items.len == 0) {
            return error.NoFoldersConfigured;
        }

        allocator.free(config.folders);
        config.folders = try folders.toOwnedSlice(allocator);

        allocator.free(config.local_copy_workers);
        config.local_copy_workers = try local_copy_workers.toOwnedSlice(allocator);
    }
};
