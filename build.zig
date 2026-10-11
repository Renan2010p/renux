// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Top-level build.
//
// The kernel (sys/), the C library (lib/), the user programs (bin/) and the
// system programs (sbin/) each have their own build.zig and working zig-out/.
// This file drives them and collects the finished products into the root
// zig-out/:
//
//   zig-out/bin/kernel      the kernel image
//   zig-out/bin/init        the first user process
//   zig-out/bin/sh          the command shell
//   zig-out/zenbsd.iso      the bootable ISO image
//
// Targets:
//   zig build buildkernel    build the kernel
//   zig build buildlib       build the C library
//   zig build buildbin       build the user programs (bin/)
//   zig build buildsbin      build the system programs (sbin/)
//   zig build builduserland  build bin/ and sbin/
//   zig build iso            build a bootable ISO
//   zig build run            boot the ISO in QEMU
//   zig build all            everything

const std: type = @import("std");
const Builder: type = std.Build;

/// The running zig executable, used to invoke the sub-builds.
fn zig(b: *Builder) []const u8 {
    return b.graph.zig_exe;
}

pub fn build(b: *Builder) !void {
    // zig build buildkernel
    const buildkernel_step: *Builder.Step = b.step("buildkernel", "Build the ZenBSD kernel");
    const buildkernel: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build" });
    buildkernel.setCwd(b.path("sys"));
    const install_kernel: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(b.path("sys/zig-out/bin/kernel"), .bin, "kernel");
    install_kernel.step.dependOn(&buildkernel.step);
    buildkernel_step.dependOn(&install_kernel.step);

    // zig build buildlib
    const buildlib_step: *Builder.Step = b.step("buildlib", "Build the ZenBSD C library");
    const buildlib: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build" });
    buildlib.setCwd(b.path("lib"));
    buildlib_step.dependOn(&buildlib.step);

    // zig build buildbin  (the shell)
    const buildbin_step: *Builder.Step = b.step("buildbin", "Build the ZenBSD user programs (bin/)");
    const buildbin: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build" });
    buildbin.setCwd(b.path("bin"));
    const install_sh: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(b.path("bin/zig-out/bin/sh"), .bin, "sh");
    install_sh.step.dependOn(&buildbin.step);
    buildbin_step.dependOn(&install_sh.step);

    // zig build buildsbin  (init)
    const buildsbin_step: *Builder.Step = b.step("buildsbin", "Build the ZenBSD system programs (sbin/)");
    const buildsbin: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build" });
    buildsbin.setCwd(b.path("sbin"));
    const install_init: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(b.path("sbin/zig-out/bin/init"), .bin, "init");
    install_init.step.dependOn(&buildsbin.step);
    buildsbin_step.dependOn(&install_init.step);

    // zig build buildlibexec  (getty)
    const buildlibexec_step: *Builder.Step = b.step("buildlibexec", "Build the ZenBSD libexec programs (libexec/)");
    const buildlibexec: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build" });
    buildlibexec.setCwd(b.path("libexec"));
    const install_getty: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(b.path("libexec/zig-out/bin/getty"), .bin, "getty");
    install_getty.step.dependOn(&buildlibexec.step);
    buildlibexec_step.dependOn(&install_getty.step);

    // zig build buildusrbin  (login, stat)
    const buildusrbin_step: *Builder.Step = b.step("buildusrbin", "Build the ZenBSD user commands (usr.bin/)");
    const buildusrbin: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build" });
    buildusrbin.setCwd(b.path("usr.bin"));
    const install_login: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(b.path("usr.bin/zig-out/bin/login"), .bin, "login");
    install_login.step.dependOn(&buildusrbin.step);
    const install_stat: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(b.path("usr.bin/zig-out/bin/stat"), .bin, "stat");
    install_stat.step.dependOn(&buildusrbin.step);
    buildusrbin_step.dependOn(&install_login.step);
    buildusrbin_step.dependOn(&install_stat.step);

    // zig build builduserland
    const builduserland_step: *Builder.Step = b.step("builduserland", "Build the ZenBSD userland");
    builduserland_step.dependOn(buildbin_step);
    builduserland_step.dependOn(buildsbin_step);
    builduserland_step.dependOn(buildlibexec_step);
    builduserland_step.dependOn(buildusrbin_step);

    // zig build iso
    const iso_step: *Builder.Step = b.step("iso", "Build a bootable ZenBSD ISO image");
    const iso: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build", "iso" });
    iso.setCwd(b.path("sys"));
    iso.step.dependOn(&install_kernel.step);
    iso.step.dependOn(buildbin_step);
    iso.step.dependOn(buildsbin_step);
    iso.step.dependOn(buildlibexec_step);
    iso.step.dependOn(buildusrbin_step);
    const install_iso: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(b.path("sys/zig-out/zenbsd.iso"), .{ .custom = "." }, "zenbsd.iso");
    install_iso.step.dependOn(&iso.step);
    iso_step.dependOn(&install_iso.step);

    // zig build run
    const run_step: *Builder.Step = b.step("run", "Boot ZenBSD in QEMU");
    const run: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build", "run" });
    run.setCwd(b.path("sys"));
    run.step.dependOn(buildbin_step);
    run.step.dependOn(buildsbin_step);
    run_step.dependOn(&run.step);

    // zig build all
    const all_step: *Builder.Step = b.step("all", "Build the kernel, library, userland and ISO");
    all_step.dependOn(iso_step);

    // A plain `zig build` builds the kernel, library and userland.
    b.default_step.dependOn(buildkernel_step);
    b.default_step.dependOn(buildlib_step);
    b.default_step.dependOn(buildbin_step);
    b.default_step.dependOn(buildsbin_step);
    b.default_step.dependOn(buildlibexec_step);
    b.default_step.dependOn(buildusrbin_step);
}
