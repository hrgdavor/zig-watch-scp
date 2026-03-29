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
        ssh2_lib.linkLibrary(zlib_dep.?.artifact("z"));
    }
    ssh2_lib.linkLibrary(mbedtls_dep.artifact("mbedtls"));

    const simargs_dep = b.dependency("simargs", .{
        .target = target,
        .optimize = optimize,
    });
    const simargs_mod = simargs_dep.module("simargs");

    const exe = b.addExecutable(.{
        .name = "sync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sync.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "simargs", .module = simargs_mod },
            },
        }),
    });

    if (use_zlib) {
        exe.linkLibrary(zlib_dep.?.artifact("z"));
    }
    exe.linkLibrary(mbedtls_dep.artifact("mbedtls"));
    exe.linkLibrary(libssh2_dep.artifact("ssh2"));
    exe.linkLibC();

    const build_opts = b.addOptions();
    const use_coreservices = target.result.os.tag == .macos and builtin.os.tag == .macos;
    build_opts.addOption(bool, "use_coreservices", use_coreservices);
    exe.root_module.addOptions("build_options", build_opts);

    if (use_coreservices) {
        exe.linkFramework("CoreServices");
        if (b.sysroot) |sysroot| {
            exe.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
        }
    }

    // Cross-building for macOS from non-macOS hosts may not have CoreServices SDK available.
    // In that case, skip framework linking to avoid invalid toolchain errors.
    if (optimize != .Debug) {
        exe.root_module.strip = true;
    }

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
