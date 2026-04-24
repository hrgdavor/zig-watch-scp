// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode") orelse .ReleaseSafe;

    const use_zlib = target.result.os.tag != .windows;

    const zlib_dep = if (use_zlib) b.dependency("zlib", .{
        .target = target,
        .optimize = optimize,
    }) else null;

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
    if (use_zlib) {
        ssh2_lib.root_module.linkLibrary(zlib_dep.?.artifact("z"));
    }
    ssh2_lib.root_module.linkLibrary(mbedtls_dep.artifact("mbedtls"));

    const exe = b.addExecutable(.{
        .name = "sync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sync.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    if (use_zlib) {
        exe.root_module.linkLibrary(zlib_dep.?.artifact("z"));
    }
    exe.root_module.linkLibrary(mbedtls_dep.artifact("mbedtls"));
    exe.root_module.linkLibrary(libssh2_dep.artifact("ssh2"));
    exe.root_module.link_libc = true;

    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("ws2_32", .{});
    }

    const build_opts = b.addOptions();
    const use_coreservices = target.result.os.tag == .macos and builtin.os.tag == .macos;
    build_opts.addOption(bool, "use_coreservices", use_coreservices);
    exe.root_module.addOptions("build_options", build_opts);

    if (use_coreservices) {
        exe.root_module.linkFramework("CoreServices", .{});
        if (b.sysroot) |sysroot| {
            exe.root_module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
            exe.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }) });
        }
    }

    // Cross-building for macOS from non-macOS hosts may not have CoreServices SDK available.
    // In that case, skip framework linking to avoid invalid toolchain errors.
    if (optimize != .Debug) {
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
            \\#ifdef __APPLE__
            \\#include <CoreServices/CoreServices.h>
            \\#endif
        ),
        .target = target,
        .optimize = optimize,
    });
    const libssh2_upstream = b.dependency("libssh2_upstream", .{});
    c_translate.addIncludePath(libssh2_upstream.path("include"));
    c_translate.addIncludePath(b.path("src"));
    if (use_coreservices) {
        if (b.sysroot) |sysroot| {
            c_translate.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
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

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
