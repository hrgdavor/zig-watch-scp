// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode") orelse .ReleaseSafe;

    const zlib_dep = b.dependency("zlib", .{
        .target = target,
        .optimize = optimize,
    });

    const mbedtls_dep = b.dependency("mbedtls", .{
        .target = target,
        .optimize = optimize,
    });

    const libssh2_dep = b.dependency("libssh2", .{
        .target = target,
        .optimize = optimize,
        .@"crypto-backend" = .mbedtls,
        .@"link-system-crypto-backend" = false,
        .zlib = true,
    });

    const ssh2_lib = libssh2_dep.artifact("ssh2");
    ssh2_lib.linkLibrary(zlib_dep.artifact("z"));
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

    exe.linkLibrary(zlib_dep.artifact("z"));
    exe.linkLibrary(mbedtls_dep.artifact("mbedtls"));
    exe.linkLibrary(libssh2_dep.artifact("ssh2"));
    exe.linkLibC();

    if (target.result.os.tag == .macos) {
        exe.linkFramework("CoreServices");
    }
    if (optimize != .Debug) {
        exe.root_module.strip = true;
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
