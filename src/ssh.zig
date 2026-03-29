// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const c = @cImport({
    @cDefine("LIBSSH2_STATIC", "1");
    @cInclude("libssh2.h");
    @cInclude("libssh2_sftp.h");
});

pub const SshSession = struct {
    session: *c.LIBSSH2_SESSION,
    sock: std.posix.socket_t,
    allocator: std.mem.Allocator,
    sftp: ?*c.LIBSSH2_SFTP,

    pub fn libInit() !void {
        if (c.libssh2_init(0) != 0) {
            return error.LibsshInitFailed;
        }
    }

    pub fn libExit() void {
        c.libssh2_exit();
    }

    pub fn printLastError(session: *c.LIBSSH2_SESSION, prefix: []const u8) void {
        var errmsg: [*c]u8 = null;
        var errmsg_len: c_int = 0;
        const err_code = c.libssh2_session_last_error(session, &errmsg, &errmsg_len, 1);
        if (errmsg_len > 0 and errmsg != null) {
            std.debug.print("{s}: libssh2 error ({}): {s}\n", .{ prefix, err_code, errmsg[0..@intCast(errmsg_len)] });
        } else {
            std.debug.print("{s}: libssh2 error ({})\n", .{ prefix, err_code });
        }
    }

    pub fn init(
        allocator: std.mem.Allocator,
        host: []const u8,
        username: []const u8,
        password: []const u8,
        key_path: []const u8,
        passphrase: []const u8,
        compress: bool,
    ) !SshSession {
        // Note: libssh2_init should be called once in main() for thread safety
        // if (c.libssh2_init(0) != 0) {
        //     return error.LibsshInitFailed;
        // }

        // Parse host and port
        var host_str = host;
        var port: u16 = 22;
        if (std.mem.indexOf(u8, host, ":")) |colon_pos| {
            host_str = host[0..colon_pos];
            port = try std.fmt.parseInt(u16, host[colon_pos + 1 ..], 10);
        }

        // Create socket
        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        errdefer std.posix.close(sock);

        // Resolve hostname
        const addr_list = try std.net.getAddressList(allocator, host_str, port);
        defer addr_list.deinit();

        if (addr_list.addrs.len == 0) {
            return error.HostNotFound;
        }

        // Connect
        try std.posix.connect(sock, &addr_list.addrs[0].any, addr_list.addrs[0].getOsSockLen());

        // Create SSH session
        const session = c.libssh2_session_init_ex(null, null, null, null) orelse return error.SessionInitFailed;
        errdefer _ = c.libssh2_session_free(session);

        // Set blocking mode
        c.libssh2_session_set_blocking(session, 1);

        // Perform handshake
        const lib_sock: c.libssh2_socket_t = if (@import("builtin").os.tag == .windows)
            @intCast(@intFromPtr(sock))
        else
            @intCast(sock);

        if (c.libssh2_session_handshake(session, lib_sock) != 0) {
            printLastError(session, "Handshake failed");
            return error.HandshakeFailed;
        }

        // Enable compression if requested
        if (compress) {
            _ = c.libssh2_session_flag(session, c.LIBSSH2_FLAG_COMPRESS, 1);
        }

        // Authenticate
        const username_z = try allocator.dupeZ(u8, username);
        defer allocator.free(username_z);

        if (key_path.len > 0) {
            const key_path_z = try allocator.dupeZ(u8, key_path);
            defer allocator.free(key_path_z);
            // Normalize in place
            for (key_path_z) |*c_ptr| {
                if (c_ptr.* == '\\') c_ptr.* = '/';
            }

            // Try to use .pub file if it exists, otherwise pass null to let libssh2 derive it
            const is_ppk = std.mem.endsWith(u8, key_path, ".ppk");

            if (is_ppk) {
                std.debug.print("Error: PuTTY Private Key (.ppk) files are not supported directly.\n", .{});
                std.debug.print("Please convert your key to OpenSSH format using PuTTYgen:\n", .{});
                std.debug.print("  puttygen \"{s}\" -O private-openssh -o \"{s}.pem\"\n", .{ key_path, key_path[0 .. key_path.len - 4] });
                std.debug.print("Then update your config to use the new .pem file.\n", .{});
                return error.PpkNotSupported;
            }

            std.debug.print("libssh2 version: {s}\n", .{c.libssh2_version(0)});
            std.debug.print("Trying Key File authentication for user '{s}' with key '{s}'\n", .{ username, key_path_z });

            // Verify file accessibility
            std.fs.accessAbsolute(key_path_z, .{}) catch |err| {
                std.debug.print("Error: Cannot access private key file {s}: {s}\n", .{ key_path_z, @errorName(err) });
                return error.KeyReadFailed;
            };

            // Check for .pub file and read its content
            var pub_key_path_z: ?[:0]u8 = null;
            var pub_key_content: ?[]u8 = null;
            const pub_key_path = try std.fmt.allocPrint(allocator, "{s}.pub", .{key_path_z});
            defer allocator.free(pub_key_path);
            if (std.fs.accessAbsolute(pub_key_path, .{})) |_| {
                pub_key_path_z = try allocator.dupeZ(u8, pub_key_path);
                pub_key_content = std.fs.cwd().readFileAlloc(allocator, pub_key_path, 4096) catch null;
                if (pub_key_content) |_| {
                    std.debug.print("Found and read public key file: {s}\n", .{pub_key_path});
                }
            } else |_| {
                std.debug.print("No .pub file found at {s}\n", .{pub_key_path});
            }
            defer if (pub_key_path_z) |p| allocator.free(p);
            defer if (pub_key_content) |c_val| allocator.free(c_val);

            const passphrase_z = if (passphrase.len > 0) try allocator.dupeZ(u8, passphrase) else null;
            defer if (passphrase_z) |p| allocator.free(p);
            const passphrase_ptr = if (passphrase_z) |p| p.ptr else null;

            // Attempt public key authentication from file
            std.debug.print("Trying public key authentication (fromfile_ex)...\n", .{});
            var auth_result = c.libssh2_userauth_publickey_fromfile_ex(
                session,
                username_z.ptr,
                @intCast(username.len),
                if (pub_key_path_z) |p| p.ptr else null,
                key_path_z.ptr,
                passphrase_ptr,
            );

            if (auth_result != 0) {
                std.debug.print("fromfile_ex result: {} / 0x{X}\n", .{ auth_result, @as(u32, @bitCast(auth_result)) });
                printLastError(session, "Public key auth (file) failed");

                // Try frommemory as fallback
                std.debug.print("Trying public key authentication (frommemory)...\n", .{});
                const priv_key_raw = std.fs.cwd().readFileAlloc(allocator, key_path_z, 1024 * 1024) catch |err| {
                    std.debug.print("Error reading private key file: {s}\n", .{@errorName(err)});
                    return error.KeyReadFailed;
                };
                defer allocator.free(priv_key_raw);

                auth_result = c.libssh2_userauth_publickey_frommemory(
                    session,
                    username_z.ptr,
                    @intCast(username.len),
                    if (pub_key_content) |c_val| c_val.ptr else null,
                    if (pub_key_content) |c_val| c_val.len else 0,
                    priv_key_raw.ptr,
                    @intCast(priv_key_raw.len),
                    passphrase_ptr,
                );
            }

            if (auth_result == 0) {
                std.debug.print("Key-based authentication successful!\n", .{});
                return SshSession{
                    .session = session,
                    .sock = sock,
                    .allocator = allocator,
                    .sftp = null,
                };
            } else {
                std.debug.print("All key-based authentication failed (final result: {} / 0x{X})\n", .{ auth_result, @as(u32, @bitCast(auth_result)) });
                printLastError(session, "Key-based auth failed");

                // Final fallback to password
                if (password.len > 0) {
                    std.debug.print("Trying password fallback...\n", .{});
                    const password_z = try allocator.dupeZ(u8, password);
                    defer allocator.free(password_z);
                    if (c.libssh2_userauth_password_ex(
                        session,
                        username_z.ptr,
                        @intCast(username.len),
                        password_z.ptr,
                        @intCast(password.len),
                        null,
                    ) == 0) {
                        std.debug.print("Password authentication successful!\n", .{});
                        return SshSession{
                            .session = session,
                            .sock = sock,
                            .allocator = allocator,
                            .sftp = null,
                        };
                    } else {
                        printLastError(session, "Password authentication failed");
                    }
                }
                return error.AuthenticationFailed;
            }
        }

        // Fall back to password auth
        const password_z = try allocator.dupeZ(u8, password);
        defer allocator.free(password_z);

        if (c.libssh2_userauth_password_ex(
            session,
            username_z.ptr,
            @intCast(username.len),
            password_z.ptr,
            @intCast(password.len),
            null,
        ) != 0) {
            printLastError(session, "Password authentication failed");
            return error.AuthenticationFailed;
        }

        return SshSession{
            .session = session,
            .sock = sock,
            .allocator = allocator,
            .sftp = null,
        };
    }

    pub fn deinit(self: *SshSession) void {
        if (self.sftp) |sftp| {
            _ = c.libssh2_sftp_shutdown(sftp);
            self.sftp = null;
        }
        _ = c.libssh2_session_disconnect(self.session, "Finished");
        _ = c.libssh2_session_free(self.session);
        std.posix.close(self.sock);
        // Note: libssh2_exit should be called once at the end of main()
        // c.libssh2_exit();
    }

    fn getSftp(self: *SshSession) !*c.LIBSSH2_SFTP {
        if (self.sftp) |sftp| return sftp;
        const sftp = c.libssh2_sftp_init(self.session) orelse return error.SftpInitFailed;
        self.sftp = sftp;
        return sftp;
    }

    /// Download a file from remote server
    pub fn downloadFile(self: *SshSession, remote_path: []const u8, local_path: []const u8) !void {
        const sftp = try self.getSftp();

        const remote_path_z = try self.allocator.dupeZ(u8, remote_path);
        defer self.allocator.free(remote_path_z);

        const remote_file = c.libssh2_sftp_open_ex(
            sftp,
            remote_path_z.ptr,
            @intCast(remote_path.len),
            c.LIBSSH2_FXF_READ,
            0,
            c.LIBSSH2_SFTP_OPENFILE,
        ) orelse return error.RemoteFileOpenFailed;
        defer _ = c.libssh2_sftp_close(remote_file);

        const local_file = try std.fs.cwd().createFile(local_path, .{});
        defer local_file.close();

        var buffer: [8192]u8 = undefined;
        while (true) {
            const bytes_read = c.libssh2_sftp_read(remote_file, &buffer, buffer.len);
            if (bytes_read < 0) {
                return error.ReadFailed;
            }
            if (bytes_read == 0) break;

            try local_file.writeAll(buffer[0..@intCast(bytes_read)]);
        }
    }

    /// Upload a file to remote server
    pub fn uploadFile(self: *SshSession, local_path: []const u8, remote_path: []const u8, simple_log: bool) !void {
        const local_file = try std.fs.cwd().openFile(local_path, .{});
        defer local_file.close();

        const stat = try local_file.stat();
        return self.uploadInternal(local_file.deprecatedReader(), stat.size, remote_path, simple_log);
    }

    /// Upload a buffer to remote server
    pub fn uploadBuffer(self: *SshSession, buffer: []const u8, remote_path: []const u8, simple_log: bool) !void {
        var fbs = std.io.fixedBufferStream(buffer);
        return self.uploadInternal(fbs.reader(), buffer.len, remote_path, simple_log);
    }

    fn uploadInternal(self: *SshSession, reader: anytype, size: u64, remote_path: []const u8, simple_log: bool) !void {
        const sftp = try self.getSftp();

        const remote_path_z = try self.allocator.dupeZ(u8, remote_path);
        defer self.allocator.free(remote_path_z);

        const remote_file = c.libssh2_sftp_open_ex(
            sftp,
            remote_path_z.ptr,
            @intCast(remote_path.len),
            c.LIBSSH2_FXF_WRITE | c.LIBSSH2_FXF_CREAT | c.LIBSSH2_FXF_TRUNC,
            @as(c_int, @intCast(c.LIBSSH2_SFTP_S_IRUSR | c.LIBSSH2_SFTP_S_IWUSR | c.LIBSSH2_SFTP_S_IRGRP | c.LIBSSH2_SFTP_S_IROTH)),
            c.LIBSSH2_SFTP_OPENFILE,
        ) orelse {
            const err_code = c.libssh2_sftp_last_error(sftp);
            std.debug.print("CRITICAL: Failed to open remote file '{s}' for writing. SFTP error code: {}\n", .{ remote_path, err_code });
            if (err_code == c.LIBSSH2_FX_NO_SUCH_FILE) {
                std.debug.print("HINT: This usually means the parent directory does not exist or you don't have permission to create it.\n", .{});
            }
            return error.RemoteFileOpenFailed;
        };
        defer _ = c.libssh2_sftp_close(remote_file);

        var buffer: [32768]u8 = undefined;
        var total_written: usize = 0;
        var last_progress: usize = 0;

        while (total_written < size) {
            const bytes_read = try reader.read(&buffer);
            if (bytes_read == 0) break;

            var written: usize = 0;
            while (written < bytes_read) {
                const bytes_written = c.libssh2_sftp_write(
                    remote_file,
                    buffer[written..].ptr,
                    bytes_read - written,
                );
                if (bytes_written < 0) {
                    return error.WriteFailed;
                }
                if (bytes_written == 0) {
                    continue;
                }
                written += @intCast(bytes_written);
            }
            total_written += bytes_read;

            // Print progress every 1MB
            if (total_written - last_progress > 1024 * 1024) {
                if (simple_log) {
                    std.debug.print("  Progress: {} / {} bytes ({}%)\n", .{ total_written, size, (total_written * 100) / size });
                } else {
                    std.debug.print("  Progress: {} / {} bytes ({}%)\r", .{ total_written, size, (total_written * 100) / size });
                }
                last_progress = total_written;
            }
        }
        if (size > 1024 * 1024 and !simple_log) {
            std.debug.print("\n", .{});
        }
    }

    /// List all files in a remote directory recursively
    pub fn listRemoteFilesRecursive(self: *SshSession, allocator: std.mem.Allocator, remote_path: []const u8) ![]const []const u8 {
        const sftp = try self.getSftp();

        var files = std.ArrayList([]const u8).empty;
        errdefer {
            for (files.items) |f| allocator.free(f);
            files.deinit(allocator);
        }

        var dir_stack = std.ArrayList([]const u8).empty;
        defer {
            for (dir_stack.items) |d| allocator.free(d);
            dir_stack.deinit(allocator);
        }

        try dir_stack.append(allocator, try allocator.dupe(u8, remote_path));

        while (dir_stack.items.len > 0) {
            const current_dir = dir_stack.items[dir_stack.items.len - 1];
            dir_stack.items.len -= 1;
            defer allocator.free(current_dir);

            const current_dir_z = try allocator.dupeZ(u8, current_dir);
            defer allocator.free(current_dir_z);

            const handle = c.libssh2_sftp_open_ex(
                sftp,
                current_dir_z.ptr,
                @intCast(current_dir.len),
                0,
                0,
                c.LIBSSH2_SFTP_OPENDIR,
            ) orelse {
                // If it's not a directory or doesn't exist, just continue
                continue;
            };
            defer _ = c.libssh2_sftp_close(handle);

            var buffer: [512]u8 = undefined;
            var attrs: c.LIBSSH2_SFTP_ATTRIBUTES = undefined;

            while (true) {
                const res = c.libssh2_sftp_readdir_ex(
                    handle,
                    &buffer,
                    buffer.len,
                    null,
                    0,
                    &attrs,
                );

                if (res <= 0) break;

                const name = buffer[0..@intCast(res)];
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

                var full_path = std.ArrayList(u8).empty;
                defer full_path.deinit(allocator);

                try full_path.appendSlice(allocator, current_dir);
                if (current_dir.len > 0 and current_dir[current_dir.len - 1] != '/') {
                    try full_path.append(allocator, '/');
                }
                try full_path.appendSlice(allocator, name);

                if ((attrs.flags & c.LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0 and (attrs.permissions & c.LIBSSH2_SFTP_S_IFDIR) != 0) {
                    try dir_stack.append(allocator, try full_path.toOwnedSlice(allocator));
                } else {
                    try files.append(allocator, try full_path.toOwnedSlice(allocator));
                }
            }
        }

        return try files.toOwnedSlice(allocator);
    }

    /// Remove a remote file
    pub fn removeRemoteFile(self: *SshSession, remote_path: []const u8) !void {
        const sftp = try self.getSftp();
        const remote_path_z = try self.allocator.dupeZ(u8, remote_path);
        defer self.allocator.free(remote_path_z);

        if (c.libssh2_sftp_unlink_ex(sftp, remote_path_z.ptr, @intCast(remote_path.len)) != 0) {
            return error.RemoteDeleteFailed;
        }
    }

    /// Remove a remote directory
    pub fn removeRemoteDir(self: *SshSession, remote_path: []const u8) !void {
        const sftp = try self.getSftp();
        const remote_path_z = try self.allocator.dupeZ(u8, remote_path);
        defer self.allocator.free(remote_path_z);

        if (c.libssh2_sftp_rmdir_ex(sftp, remote_path_z.ptr, @intCast(remote_path.len)) != 0) {
            return error.RemoteDeleteFailed;
        }
    }

    /// Create remote directory (recursive)
    pub fn createRemoteDir(self: *SshSession, remote_path: []const u8) !void {
        const sftp = try self.getSftp();

        // Normalize slashes
        const normalized = try self.allocator.dupe(u8, remote_path);
        defer self.allocator.free(normalized);
        std.mem.replaceScalar(u8, normalized, '\\', '/');

        var it = std.mem.splitScalar(u8, normalized, '/');
        var current_path = std.ArrayList(u8).empty;
        defer current_path.deinit(self.allocator);

        if (normalized.len > 0 and normalized[0] == '/') {
            try current_path.append(self.allocator, '/');
        }

        while (it.next()) |part| {
            if (part.len == 0) continue;

            if (current_path.items.len > 0 and current_path.items[current_path.items.len - 1] != '/') {
                try current_path.append(self.allocator, '/');
            }
            try current_path.appendSlice(self.allocator, part);

            // Create a temporary null-terminated string for this path component
            const path_z = try self.allocator.dupeZ(u8, current_path.items);
            defer self.allocator.free(path_z);

            _ = c.libssh2_sftp_mkdir_ex(
                sftp,
                path_z.ptr,
                @intCast(path_z.len),
                @as(c_int, @intCast(c.LIBSSH2_SFTP_S_IRWXU | c.LIBSSH2_SFTP_S_IRGRP | c.LIBSSH2_SFTP_S_IXGRP | c.LIBSSH2_SFTP_S_IROTH | c.LIBSSH2_SFTP_S_IXOTH)),
            );
        }
    }

    /// Execute a remote command and print its output
    pub fn exec(self: *SshSession, command: []const u8) !void {
        const channel = c.libssh2_channel_open_ex(self.session, "session", @intCast("session".len), c.LIBSSH2_CHANNEL_WINDOW_DEFAULT, c.LIBSSH2_CHANNEL_PACKET_DEFAULT, null, 0) orelse return error.ChannelOpenFailed;
        defer _ = c.libssh2_channel_free(channel);

        const command_z = try self.allocator.dupeZ(u8, command);
        defer self.allocator.free(command_z);

        if (c.libssh2_channel_process_startup(channel, "exec", @intCast("exec".len), command_z.ptr, @intCast(command.len)) != 0) {
            return error.ChannelExecFailed;
        }

        std.debug.print("Executing: {s}\n", .{command});

        while (true) {
            var buffer: [4096]u8 = undefined;
            const rc = c.libssh2_channel_read_ex(channel, 0, &buffer, buffer.len);
            if (rc < 0) return error.ChannelReadFailed;
            if (rc == 0) break;
            std.debug.print("{s}", .{buffer[0..@intCast(rc)]});
        }

        _ = c.libssh2_channel_send_eof(channel);
        _ = c.libssh2_channel_wait_eof(channel);
        _ = c.libssh2_channel_wait_closed(channel);
    }
};
