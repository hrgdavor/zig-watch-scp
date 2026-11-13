// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.lang.Optimize, "optimize", "Optimization mode") orelse .safe;

    const use_zlib = target.result.os.tag != .windows;

    const mbedtls_dep = b.dependency("mbedtls", .{
        .target = target,
        .optimize = optimize,
    });

    const libssh2_dep = b.dependency("libssh2", .{
        .target = target,
        .optimize = optimize,
        .@"crypto-backend" = .mbedtls,
        .@"link-system-crypto-backend" = false,
        .zlib = use_zlib,
    });

    const ssh2_lib = libssh2_dep.artifact("ssh2");
    if (target.result.os.tag != .windows) {
        // The upstream Zig package does not define this, so libssh2 fails to put
        // its socket in non-blocking mode on POSIX. Its blocking API then hangs
        // in the channel-write drain loop (notably at the first SFTP write).
        ssh2_lib.root_module.addCMacro("HAVE_O_NONBLOCK", "1");
    }
    // libssh2 pulls in its own pinned zlib dependency when `use_zlib` is enabled.
    // No separate top-level zlib dependency is needed.
    ssh2_lib.root_module.linkLibrary(mbedtls_dep.artifact("mbedtls"));

    const exe = b.addExecutable(.{
        .name = "sync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sync.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.linkLibrary(mbedtls_dep.artifact("mbedtls"));
    exe.root_module.linkLibrary(libssh2_dep.artifact("ssh2"));
    exe.root_module.link_libc = true;

    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("ws2_32", .{});
    }

    const build_opts = b.addOptions();
    const use_nightwatch = b.option(bool, "use_nightwatch", "Enable Nightwatch backend") orelse false;
    const use_coreservices = target.result.os.tag == .macos and builtin.os.tag == .macos;
    
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

    build_opts.addOption(bool, "use_nightwatch", use_nightwatch);
    build_opts.addOption(bool, "use_coreservices", use_coreservices);
    build_opts.addOption([]const u8, "version", version);
    exe.root_module.addOptions("config", build_opts);

    const nightwatch_dep = b.dependency("nightwatch", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("nightwatch", nightwatch_dep.module("nightwatch"));

    if (use_coreservices) {
        exe.root_module.linkFramework("CoreServices", .{});
        if (b.sysroot) |sysroot| {
            exe.root_module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
            exe.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }) });
        }
    }

    // Cross-building for macOS from non-macOS hosts may not have CoreServices SDK available.
    // In that case, skip framework linking to avoid invalid toolchain errors.
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
            \\#ifdef __linux__
            \\#include <sys/inotify.h>
            \\#include <unistd.h>
            \\#include <limits.h>
            \\#endif
            \\// macOS headers are avoided here to bypass translate-c issues with Mach types.
            \\// CoreFoundation and FSEvents are handled via extern in watcher_macos.zig.
        ),
        .target = target,
        .optimize = optimize,
    });
    const libssh2_upstream = b.dependency("libssh2_upstream", .{});
    c_translate.addIncludePath(libssh2_upstream.path("include"));
    c_translate.addIncludePath(b.path("src"));
    if (use_coreservices) {
        if (b.sysroot) |sysroot| {
            const frameworks_path = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" });
            c_translate.addFrameworkPath(.{ .cwd_relative = frameworks_path });
            c_translate.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ frameworks_path, "CoreServices.framework/Frameworks" }) });
            c_translate.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }) });
        }
    }

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

    if (use_coreservices) {
        stats_exe.root_module.linkFramework("CoreServices", .{});
        if (b.sysroot) |sysroot| {
            stats_exe.root_module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
            stats_exe.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }) });
        }
    }

    const install_stats = b.addInstallArtifact(stats_exe, .{
        .dest_dir = .{ .override = .prefix },
    });
    b.getInstallStep().dependOn(&install_stats.step);

    const stats_step = b.step("stats", "Build the stats executable");
    stats_step.dependOn(&stats_exe.step);

    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/config_test.zig", "src/glob_test.zig" }) |test_path| {
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
