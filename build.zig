// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Top-level build.
//
// The kernel (kernel/), the C library (userland/lib/), the user programs
// (userland/bin/, userland/usr/bin/, userland/libexec/) and the system
// programs (userland/sbin/) each have their own build.zig and working zig-out/.
// This file drives them and collects the finished products into the root
// zig-out/:
//
//   zig-out/bin/kernel      the kernel image
//   zig-out/bin/init        the first user process
//   zig-out/bin/sh          the command shell
//   zig-out/renux.iso      the bootable ISO image
//
// Targets:
//   zig build buildkernel    build the kernel
//   zig build buildlib       build the C library
//   zig build buildbin       build the user programs (bin/)
//   zig build buildsbin      build the system programs (sbin/)
//   zig build builduserland  build bin/ and sbin/
//   zig build rootfs         build the root image embedded in the kernel
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
    const buildkernel_step: *Builder.Step = b.step("buildkernel", "Build the Renux kernel");
    const devbuild: bool = b.option(bool, "devbuild", "Stamp the kernel with the build date, user and host") orelse false;
    const buildkernel: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build" });
    if (devbuild) buildkernel.addArg("-Ddevbuild=true");
    buildkernel.setCwd(b.path("kernel"));
    const install_kernel: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(b.path("kernel/zig-out/bin/kernel"), .bin, "kernel");
    install_kernel.step.dependOn(&buildkernel.step);
    buildkernel_step.dependOn(&install_kernel.step);

    // zig build buildlib
    const buildlib_step: *Builder.Step = b.step("buildlib", "Build the Renux C library");
    const buildlib: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build" });
    buildlib.setCwd(b.path("userland/lib"));
    buildlib_step.dependOn(&buildlib.step);

    // zig build buildbin  (the shell)
    const buildbin_step: *Builder.Step = b.step("buildbin", "Build the Renux user programs (bin/)");
    const buildbin: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build" });
    buildbin.setCwd(b.path("userland/bin"));
    const install_sh: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(b.path("userland/bin/zig-out/bin/sh"), .bin, "sh");
    install_sh.step.dependOn(&buildbin.step);
    buildbin_step.dependOn(&install_sh.step);

    // zig build buildsbin  (init)
    const buildsbin_step: *Builder.Step = b.step("buildsbin", "Build the Renux system programs (sbin/)");
    const buildsbin: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build" });
    buildsbin.setCwd(b.path("userland/sbin"));
    const install_init: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(b.path("userland/sbin/zig-out/bin/init"), .bin, "init");
    install_init.step.dependOn(&buildsbin.step);
    buildsbin_step.dependOn(&install_init.step);

    // zig build buildlibexec  (getty)
    const buildlibexec_step: *Builder.Step = b.step("buildlibexec", "Build the Renux libexec programs (libexec/)");
    const buildlibexec: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build" });
    buildlibexec.setCwd(b.path("userland/libexec"));
    const install_getty: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(b.path("userland/libexec/zig-out/bin/getty"), .bin, "getty");
    install_getty.step.dependOn(&buildlibexec.step);
    buildlibexec_step.dependOn(&install_getty.step);

    // zig build buildusrbin  (login, stat)
    const buildusrbin_step: *Builder.Step = b.step("buildusrbin", "Build the Renux user commands (usr.bin/)");
    const buildusrbin: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build" });
    buildusrbin.setCwd(b.path("userland/usr/bin"));
    const install_login: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(b.path("userland/usr/bin/zig-out/bin/login"), .bin, "login");
    install_login.step.dependOn(&buildusrbin.step);
    const install_stat: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(b.path("userland/usr/bin/zig-out/bin/stat"), .bin, "stat");
    install_stat.step.dependOn(&buildusrbin.step);
    buildusrbin_step.dependOn(&install_login.step);
    buildusrbin_step.dependOn(&install_stat.step);

    // zig build builduserland
    const builduserland_step: *Builder.Step = b.step("builduserland", "Build the Renux userland");
    builduserland_step.dependOn(buildbin_step);
    builduserland_step.dependOn(buildsbin_step);
    builduserland_step.dependOn(buildlibexec_step);
    builduserland_step.dependOn(buildusrbin_step);

    // zig build bootloader  (our own UEFI boot loader, stand/amd64/uefi)
    const bootloader_step: *Builder.Step = b.step("bootloader", "Build the Renux UEFI boot loader (BOOTX64.EFI)");
    const bootloader: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build" });
    bootloader.setCwd(b.path("stand/efi/loader"));
    bootloader_step.dependOn(&bootloader.step);

    // zig build rootfs  (the root image embedded in the kernel; needs the userland)
    const rootfs_step: *Builder.Step = b.step("rootfs", "Build the root image embedded in the kernel");
    const rootfs: *Builder.Step.Run = b.addSystemCommand(&.{ "sh", "../tools/mkrootfs.sh" });
    rootfs.setCwd(b.path("kernel"));
    rootfs.step.dependOn(buildlib_step);
    rootfs.step.dependOn(buildbin_step);
    rootfs.step.dependOn(buildsbin_step);
    rootfs.step.dependOn(buildlibexec_step);
    rootfs.step.dependOn(buildusrbin_step);
    rootfs_step.dependOn(&rootfs.step);

    // The kernel carries the root image inside it (FreeBSD's MD_ROOT), so the
    // image has to exist before the kernel is compiled.
    buildkernel.step.dependOn(&rootfs.step);

    // zig build iso
    const iso_step: *Builder.Step = b.step("iso", "Build a bootable Renux ISO image");
    const iso: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build", "iso" });
    iso.setCwd(b.path("kernel"));
    iso.step.dependOn(&install_kernel.step);
    iso.step.dependOn(bootloader_step);
    iso.step.dependOn(buildbin_step);
    iso.step.dependOn(buildsbin_step);
    iso.step.dependOn(buildlibexec_step);
    iso.step.dependOn(buildusrbin_step);
    const install_iso: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(b.path("kernel/zig-out/renux.iso"), .{ .custom = "." }, "renux.iso");
    install_iso.step.dependOn(&iso.step);
    iso_step.dependOn(&install_iso.step);

    // zig build run
    const run_step: *Builder.Step = b.step("run", "Boot Renux in QEMU");
    const run: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build", "run" });
    run.setCwd(b.path("kernel"));
    run.step.dependOn(buildbin_step);
    run.step.dependOn(buildsbin_step);
    run_step.dependOn(&run.step);

    // zig build run-efi  (UEFI + the Renux loader, in a graphical window)
    const run_efi_step: *Builder.Step = b.step("run-efi", "Boot Renux in QEMU through UEFI, in a window");
    const run_efi: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build", "run-efi" });
    run_efi.setCwd(b.path("kernel"));
    run_efi.step.dependOn(iso_step);
    run_efi_step.dependOn(&run_efi.step);

    // zig build test  (host unit tests for the pure, portable parts)
    const test_step: *Builder.Step = b.step("test", "Run the host unit tests");
    const unit: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "test", "kernel/vm/phys_bitmap.zig" });
    unit.setCwd(b.path("."));
    test_step.dependOn(&unit.step);
    const clock_unit: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "test", "kernel/core/subr_clock.zig" });
    clock_unit.setCwd(b.path("."));
    test_step.dependOn(&clock_unit.step);
    const ioc_unit: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "test", "kernel/sys/ioccom.zig" });
    ioc_unit.setCwd(b.path("."));
    test_step.dependOn(&ioc_unit.step);

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
