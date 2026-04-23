// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");

pub const Folder = struct {
    scpdb: []const u8,
    local_db: bool,
    local_dir: []const u8,
    remote_dir: []const u8,
    include_patterns: []const []const u8,
    exclude_patterns: []const []const u8,
    trigger_from: ?[]const u8,
    trigger_to: ?[]const u8,
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
    watch: bool,
    color: bool,

    // Standalone create mode
    create_folder: ?[]const u8,
    create_includes: []const []const u8,
    create_excludes: []const []const u8,

    // Standalone get/put mode
    get_file: ?[2][]const u8,
    put_file: ?[2][]const u8,

    // ─────────────────────────────────────────────────────────────────────────
    // parseArgs  (native — no external dependency)
    // ─────────────────────────────────────────────────────────────────────────

    /// Parse command-line arguments collected by the caller (skip argv[0]).
    /// Supports flags: -c/--config, -x/--compress, --simple-log, --cleanup,
    ///   --watch-delay <ms>, --exec <cmd>, -h/--help
    /// Subcommands: get <remote> <local>  |  put <local> <remote>  |  create <folder>
    pub fn parseArgs(arena_allocator: std.mem.Allocator, init: std.process.Init, raw_args: []const []const u8) !Config {
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
        var cli_watch: bool = false;
        var cli_color: bool = true;
        var config_path: ?[]const u8 = null;
        var cli_host: ?[]const u8 = null;
        var cli_username: ?[]const u8 = null;
        var cli_password: ?[]const u8 = null;

        // ── subcommand / flag scanning ─────────────────────────────────────────
        // Subcommands recognized: get, put, create.
        // Everything before the subcommand is a flag or positional.
        const Subcmd = enum { none, get, put, create };
        var subcmd: Subcmd = .none;
        // create-subcommand-specific flags
        var create_includes_raw: ?[]const u8 = null;
        var create_excludes_raw: ?[]const u8 = null;
        // positionals collected before/after subcommand
        var positionals = std.ArrayList([]const u8).empty;
        // post-subcommand positionals (paths for get/put/create)
        var sub_positionals = std.ArrayList([]const u8).empty;

        var i: usize = 0;
        while (i < raw_args.len) : (i += 1) {
            const arg = raw_args[i];

            // ── detect subcommand ─────────────────────────────────────────
            if (subcmd == .none and !std.mem.startsWith(u8, arg, "-")) {
                if (std.mem.eql(u8, arg, "get")) {
                    subcmd = .get;
                    continue;
                }
                if (std.mem.eql(u8, arg, "put")) {
                    subcmd = .put;
                    continue;
                }
                if (std.mem.eql(u8, arg, "create")) {
                    subcmd = .create;
                    continue;
                }
                // plain positional (host / username / password / lone config path)
                try positionals.append(arena_allocator, arg);
                continue;
            }

            // ── after subcommand: collect flags + positionals ──────────────
            if (subcmd != .none) {
                if (std.mem.eql(u8, arg, "--includes") or std.mem.eql(u8, arg, "--include")) {
                    i += 1;
                    if (i >= raw_args.len) return error.MissingArgValue;
                    create_includes_raw = raw_args[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--excludes") or std.mem.eql(u8, arg, "--exclude")) {
                    i += 1;
                    if (i >= raw_args.len) return error.MissingArgValue;
                    create_excludes_raw = raw_args[i];
                    continue;
                }
                if (!std.mem.startsWith(u8, arg, "-")) {
                    try sub_positionals.append(arena_allocator, arg);
                    continue;
                }
                // fall through to shared flag handling
            }

            // ── shared flags ─────────────────────────────────────────────
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                printHelp();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
                i += 1;
                if (i >= raw_args.len) return error.MissingArgValue;
                config_path = raw_args[i];
            } else if (std.mem.eql(u8, arg, "-x") or std.mem.eql(u8, arg, "--compress")) {
                cli_compress = true;
            } else if (std.mem.eql(u8, arg, "--no-color")) {
                cli_color = false;
            } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--watch")) {
                cli_watch = true;
            } else if (std.mem.eql(u8, arg, "--simple-log")) {
                cli_simple_log = true;
            } else if (std.mem.eql(u8, arg, "--cleanup")) {
                cli_cleanup = true;
            } else if (std.mem.eql(u8, arg, "--watch-delay")) {
                i += 1;
                if (i >= raw_args.len) return error.MissingArgValue;
                cli_watch_delay = try std.fmt.parseInt(u64, raw_args[i], 10);
            } else if (std.mem.eql(u8, arg, "--exec")) {
                i += 1;
                if (i >= raw_args.len) return error.MissingArgValue;
                cli_exec_cmd = raw_args[i];
            } else {
                std.debug.print("Error: Unknown argument: {s}\n", .{arg});
                return error.UnknownArgument;
            }
        }

        // ── resolve subcommand results ────────────────────────────────────────
        switch (subcmd) {
            .none => {
                // Positional args: single = config path, three = host/user/pass
                if (config_path == null and positionals.items.len == 1) {
                    config_path = positionals.items[0];
                } else {
                    if (positionals.items.len > 0) cli_host = positionals.items[0];
                    if (positionals.items.len > 1) cli_username = positionals.items[1];
                    if (positionals.items.len > 2) cli_password = positionals.items[2];
                }
            },
            .get => {
                if (sub_positionals.items.len < 2) {
                    std.debug.print("Error: 'get' requires <remote-path> <local-path>\n", .{});
                    return error.MissingGetPaths;
                }
                get_file = .{ sub_positionals.items[0], sub_positionals.items[1] };
            },
            .put => {
                if (sub_positionals.items.len < 2) {
                    std.debug.print("Error: 'put' requires <local-path> <remote-path>\n", .{});
                    return error.MissingPutPaths;
                }
                put_file = .{ sub_positionals.items[0], sub_positionals.items[1] };
            },
            .create => {
                if (sub_positionals.items.len < 1) {
                    std.debug.print("Error: 'create' requires <folder-path>\n", .{});
                    return error.MissingCreatePath;
                }
                create_folder = sub_positionals.items[0];
                if (create_includes_raw) |inc| {
                    var it = std.mem.tokenizeAny(u8, inc, ", \t");
                    while (it.next()) |pat| try create_includes.append(arena_allocator, try arena_allocator.dupe(u8, pat));
                }
                if (create_excludes_raw) |exc| {
                    var it = std.mem.tokenizeAny(u8, exc, ", \t");
                    while (it.next()) |pat| try create_excludes.append(arena_allocator, try arena_allocator.dupe(u8, pat));
                }
            },
        }

        // ── validation ────────────────────────────────────────────────────────
        if (config_path == null and create_folder == null and get_file == null and put_file == null) {
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
            .watch = cli_watch,
            .color = cli_color,
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
            try parseIntoConfig(arena_allocator, init.io, &config, cp);
        }

        // Resolve SSH config before environment fallbacks and validation
        try resolveSshConfig(arena_allocator, init, &config);

        // Environment variable fallbacks for credentials
        if (config.password.len == 0) {
            if (init.minimal.environ.getAlloc(arena_allocator, "SCP_PASSWORD")) |val| {
                config.password = val;
            } else |_| {}
        }
        if (config.passphrase.len == 0) {
            if (init.minimal.environ.getAlloc(arena_allocator, "SCP_PASSPHRASE")) |val| {
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

    fn printHelp() void {
        std.debug.print(
            \\Usage: sync [flags] <config-file>
            \\       sync [flags] <host> <username> <password>
            \\       sync [flags] get <remote-path> <local-path>
            \\       sync [flags] put <local-path> <remote-path>
            \\       sync [flags] create [--include <pat>] [--exclude <pat>] <folder>
            \\
            \\Flags:
            \\  -c, --config <file>       Path to configuration file
            \\  -x, --compress            Enable SSH compression
            \\      --simple-log          Simple logging (no escape codes)
            \\      --cleanup             Remove remote files not present locally
            \\      --watch-delay <ms>    Delay before syncing after change (default: 200)
            \\      --exec <cmd>          Remote command to run after sync
            \\  -w, --watch               Enable watch mode (continuous sync)
            \\      --no-color            Disable color output
            \\  -h, --help               Show this help
            \\
        , .{});
    }

    pub fn resolveSshConfig(allocator: std.mem.Allocator, init: std.process.Init, config: *Config) !void {
        var home_path: ?[]u8 = null;
        if (init.minimal.environ.getAlloc(allocator, "USERPROFILE")) |val| {
            home_path = val;
        } else |_| {
            if (init.minimal.environ.getAlloc(allocator, "HOME")) |val| {
                home_path = val;
            } else |_| {}
        }
        defer if (home_path) |hp| allocator.free(hp);

        if (home_path == null) return;

        const ssh_config_path = try std.fs.path.join(allocator, &.{ home_path.?, ".ssh", "config" });
        defer allocator.free(ssh_config_path);

        try resolveSshConfigFile(allocator, init.io, config, ssh_config_path, home_path.?);
    }

    pub fn resolveSshConfigFile(allocator: std.mem.Allocator, io: std.Io, config: *Config, path: []const u8, home_path: []const u8) !void {
        if (config.host.len == 0) return;

        const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, @as(std.Io.Limit, @enumFromInt(1024 * 1024))) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer allocator.free(content);

        const config_data = content;

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
                        const rel_path = std.mem.trimStart(u8, value[1..], "/\\");
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
                    const new_host = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ target_host, p });
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
        io: std.Io,
        config: *Config,
        file_path: []const u8,
    ) !void {
        const content = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, @as(std.Io.Limit, @enumFromInt(1024 * 1024)));
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
        var cur_trigger_from: ?[]const u8 = null;
        var cur_trigger_to: ?[]const u8 = null;

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
                t_from: *?[]const u8,
                t_to: *?[]const u8,
            ) !void {
                if (l_dir.* == null and r_dir.* == null and inc.items.len == 0 and exc.items.len == 0 and t_to.* == null) return;
                try f_list.append(alloc, .{
                    .scpdb = scpdb.* orelse try alloc.dupe(u8, ".scpdb"),
                    .local_db = local_db,
                    .local_dir = l_dir.* orelse try alloc.dupe(u8, "."),
                    .remote_dir = r_dir.* orelse try alloc.dupe(u8, "."),
                    .include_patterns = try inc.toOwnedSlice(alloc),
                    .exclude_patterns = try exc.toOwnedSlice(alloc),
                    .trigger_from = t_from.*,
                    .trigger_to = t_to.*,
                });
                l_dir.* = null;
                r_dir.* = null;
                scpdb.* = null;
                t_from.* = null;
                t_to.* = null;
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
                if (section == .folder) try pushFolder(allocator, &cur_scpdb, cur_local_db, &folders, &cur_local_dir, &cur_remote_dir, &cur_includes, &cur_excludes, &cur_trigger_from, &cur_trigger_to);
                if (section == .source) try pushLocalSource(allocator, &cur_sources, &cur_local_dir, &cur_includes, &cur_excludes);
                if (section == .local_folder) try pushLocalWorker(allocator, &local_copy_workers, &cur_dest_dir, &cur_sources);
                section = .folder;
                cur_local_db = false;
                continue;
            }

            if (std.mem.eql(u8, trimmed, "[local-folder]")) {
                if (section == .folder) try pushFolder(allocator, &cur_scpdb, cur_local_db, &folders, &cur_local_dir, &cur_remote_dir, &cur_includes, &cur_excludes, &cur_trigger_from, &cur_trigger_to);
                if (section == .source) try pushLocalSource(allocator, &cur_sources, &cur_local_dir, &cur_includes, &cur_excludes);
                if (section == .local_folder) try pushLocalWorker(allocator, &local_copy_workers, &cur_dest_dir, &cur_sources);
                section = .local_folder;
                continue;
            }

            if (std.mem.eql(u8, trimmed, "[source]")) {
                if (section == .folder) try pushFolder(allocator, &cur_scpdb, cur_local_db, &folders, &cur_local_dir, &cur_remote_dir, &cur_includes, &cur_excludes, &cur_trigger_from, &cur_trigger_to);
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
                } else if (std.mem.eql(u8, key, "trigger_from")) {
                    if (section == .folder) {
                        cur_trigger_from = try allocator.dupe(u8, value);
                    }
                } else if (std.mem.eql(u8, key, "trigger_to")) {
                    if (section == .folder) {
                        cur_trigger_to = try allocator.dupe(u8, value);
                    }
                }
            }
        }

        if (section == .folder) try pushFolder(allocator, &cur_scpdb, cur_local_db, &folders, &cur_local_dir, &cur_remote_dir, &cur_includes, &cur_excludes, &cur_trigger_from, &cur_trigger_to);
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
