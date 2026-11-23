// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.lang.Optimize, "optimize", "Optimization mode") orelse .safe;

    // fs-meta is the primary dependency. Its pinned nightwatch is used
    // transitively for this project's watcher implementation.
    const fs_meta_dep = b.dependency("fs_meta", .{
        .target = target,
        .optimize = optimize,
    });
    // Native macOS builds use FSEvents (the backend this tool used before the
    // nightwatch move). Cross-builds from non-macOS hosts keep kqueue because
    // the FSEvents path needs the Xcode frameworks.
    const use_fsevents = target.result.os.tag == .macos and builtin.os.tag == .macos;
    const nightwatch_dep = if (use_fsevents)
        fs_meta_dep.builder.dependency("nightwatch", .{
            .target = target,
            .optimize = optimize,
            .macos_fsevents = true,
        })
    else
        fs_meta_dep.builder.dependency("nightwatch", .{
            .target = target,
            .optimize = optimize,
        });

    const use_zlib = target.result.os.tag != .windows;

    const mbedtls_dep = b.dependency("mbedtls", .{
        .target = target,
        .optimize = optimize,
    });

    // libssh2 is built from the pinned upstream sources with our
    // third_party/libssh2/crypto.c override, which makes the mbedTLS backend's
    // process-global RNG safe for parallel sessions. See that file's header
    // comment for the full story.
    const ssh2_lib = addLibssh2(b, target, optimize, use_zlib);
    ssh2_lib.root_module.linkLibrary(mbedtls_dep.artifact("mbedtls"));
    if (target.result.os.tag != .windows) {
        // Zig does not define this, so libssh2 fails to put its socket in
        // non-blocking mode on POSIX. Its blocking API then hangs in the
        // channel-write drain loop (notably at the first SFTP write).
        ssh2_lib.root_module.addCMacro("HAVE_O_NONBLOCK", "1");
    }

    const exe = b.addExecutable(.{
        .name = "sync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sync.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.linkLibrary(mbedtls_dep.artifact("mbedtls"));
    exe.root_module.linkLibrary(ssh2_lib);
    exe.root_module.link_libc = true;

    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("ws2_32", .{});
    }

    const build_opts = b.addOptions();

    // Extract version from build.zig.zon
    const version = v: {
        b.dependOnFileContents(b.path("build.zig.zon"));
        const zon_file = b.root.openFile(b.graph.io, "build.zig.zon", .{}) catch break :v "0.0.0";
        defer zon_file.close(b.graph.io);
        var zon_reader_buf: [4096]u8 = undefined;
        var zon_reader = zon_file.reader(b.graph.io, &zon_reader_buf);
        const zon_content = zon_reader.interface.allocRemaining(b.allocator, std.Io.Limit.limited(1024 * 1024)) catch break :v "0.0.0";
        if (std.mem.indexOf(u8, zon_content, ".version = \"")) |idx| {
            const start = idx + ".version = \"".len;
            if (std.mem.indexOfScalarPos(u8, zon_content, start, '"')) |end| {
                break :v zon_content[start..end];
            }
        }
        break :v "0.0.0";
    };

    build_opts.addOption([]const u8, "version", version);
    exe.root_module.addOptions("config", build_opts);

    exe.root_module.addImport("nightwatch", nightwatch_dep.module("nightwatch"));

    if (optimize != .debug) {
        exe.root_module.strip = true;
    }

    // Add src/ to include paths so cImport can find socket_compat.h
    exe.root_module.addSystemIncludePath(b.path("src"));

    const c_translate = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("c_include.h",
            \\#define LIBSSH2_STATIC 1
            \\#undef _FORTIFY_SOURCE
            \\#define _FORTIFY_SOURCE 0
            \\#define __builtin_va_arg_pack_len() 0
            \\#define __builtin_va_arg_pack() 
            \\#include <libssh2.h>
            \\#include <libssh2_sftp.h>
            \\#include "socket_compat.h"
        ),
        .target = target,
        .optimize = optimize,
    });
    const libssh2_upstream = b.dependency("libssh2_upstream", .{});
    c_translate.addIncludePath(libssh2_upstream.path("include"));
    c_translate.addIncludePath(b.path("src"));

    const c_module = c_translate.addModule("c");
    exe.root_module.addImport("c", c_module);

    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .prefix },
    });

    b.getInstallStep().dependOn(&install_exe.step);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const stats_exe = b.addExecutable(.{
        .name = "stats",
        .root_module = b.createModule(.{
            .root_source_file = b.path("statistics.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    stats_exe.root_module.addSystemIncludePath(b.path("src"));
    stats_exe.root_module.addImport("c", c_module);
    stats_exe.root_module.addOptions("config", build_opts);
    stats_exe.root_module.addImport("nightwatch", nightwatch_dep.module("nightwatch"));

    const install_stats = b.addInstallArtifact(stats_exe, .{
        .dest_dir = .{ .override = .prefix },
    });
    b.getInstallStep().dependOn(&install_stats.step);

    const stats_step = b.step("stats", "Build the stats executable");
    stats_step.dependOn(&stats_exe.step);

    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/config_test.zig", "src/glob_test.zig", "src/db_path_test.zig" }) |test_path| {
        const test_exe = b.addTest(.{
            .name = std.fs.path.stem(test_path),
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_path),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_exe.root_module.addOptions("config", build_opts);
        const run_test = b.addRunArtifact(test_exe);
        test_step.dependOn(&run_test.step);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

/// Build libssh2 1.11.1 from the pinned `libssh2_upstream` sources, replacing
/// `src/crypto.c` with `third_party/libssh2/crypto.c` (thread-safe mbedTLS
/// RNG). Keeping the build here means the patch travels with the repository and
/// the release builds get no new system dependencies.
fn addLibssh2(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_zlib: bool,
) *std.Build.Step.Compile {
    const upstream = b.dependency("libssh2_upstream", .{});
    const is_windows = target.result.os.tag == .windows;

    const config_header = b.addConfigHeader(.{
        .style = .{
            .cmake = upstream.path("src/libssh2_config_cmake.h.in"),
        },
        .include_path = "libssh2_config.h",
    }, .{
        .LIBSSH2_API = if (is_windows) "__declspec(dllexport)" else "",
        .HAVE_SYS_UIO_H = !is_windows,
        .HAVE_SYS_SOCKET_H = !is_windows,
        .HAVE_NETINET_IN_H = !is_windows,
        .HAVE_ARPA_INET_H = !is_windows,
        .HAVE_INTTYPES_H = true,
    });

    const ssh2_lib = b.addLibrary(.{
        .name = "ssh2",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    ssh2_lib.root_module.addConfigHeader(config_header);
    ssh2_lib.root_module.addIncludePath(upstream.path("include"));
    ssh2_lib.root_module.addIncludePath(upstream.path("src"));
    ssh2_lib.root_module.addCMacro("HAVE_CONFIG_H", "1");
    ssh2_lib.root_module.addCMacro("LIBSSH2_MBEDTLS", "1");

    ssh2_lib.root_module.addCSourceFiles(.{
        .files = libssh2_sources,
        .root = upstream.path(""),
        .flags = &.{},
    });
    ssh2_lib.root_module.addCSourceFile(.{
        .file = b.path("third_party/libssh2/crypto.c"),
        .flags = &.{},
    });

    if (use_zlib) {
        // Not part of the CMake config template; it enables comp.c's zlib code.
        ssh2_lib.root_module.addCMacro("LIBSSH2_HAVE_ZLIB", "1");
        if (b.lazyDependency("zlib", .{ .target = target, .optimize = optimize })) |zlib_dep| {
            ssh2_lib.root_module.linkLibrary(zlib_dep.artifact("z"));
        }
    }

    return ssh2_lib;
}

/// Upstream libssh2 1.11.1 sources, minus `src/crypto.c` (replaced above).
const libssh2_sources: []const []const u8 = &.{
    "src/agent.c",
    "src/bcrypt_pbkdf.c",
    "src/blowfish.c",
    "src/chacha.c",
    "src/channel.c",
    "src/cipher-chachapoly.c",
    "src/comp.c",
    "src/crypt.c",
    "src/global.c",
    "src/hostkey.c",
    "src/keepalive.c",
    "src/kex.c",
    "src/knownhost.c",
    "src/mac.c",
    "src/misc.c",
    "src/packet.c",
    "src/pem.c",
    "src/poly1305.c",
    "src/publickey.c",
    "src/scp.c",
    "src/session.c",
    "src/sftp.c",
    "src/transport.c",
    "src/userauth.c",
    "src/userauth_kbd_packet.c",
    "src/version.c",
};
