// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Top-level build.
//
// The kernel (sys/) and the userland (sbin/) each have their own build.zig and
// their own working zig-out/. This file is the entry point at the root of the
// tree: it drives those sub-builds and collects the final artifacts into the
// root zig-out/, so the finished products live in one place:
//
//   zig-out/bin/kernel      the kernel image
//   zig-out/bin/init        the first user process
//   zig-out/zenbsd.iso      the bootable ISO image
//
// Targets:
//   zig build buildkernel    build the kernel
//   zig build builduserland  build the userland
//   zig build iso            build a bootable ISO (kernel + userland)
//   zig build run            boot the ISO in QEMU
//   zig build all            build kernel, userland and ISO

const std: type = @import("std");
const Builder: type = std.Build;

pub fn build(b: *Builder) !void {
    // zig build buildkernel: run sys/build.zig, then collect the kernel image.
    const buildkernel_step: *Builder.Step = b.step("buildkernel", "Build the ZenBSD kernel");
    const buildkernel: *Builder.Step.Run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    buildkernel.setCwd(b.path("sys"));

    const install_kernel: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(b.path("sys/zig-out/bin/kernel"), .bin, "kernel");
    install_kernel.step.dependOn(&buildkernel.step);
    buildkernel_step.dependOn(&install_kernel.step);

    // zig build buildlib: the C library (lib/).
    const buildlib_step: *Builder.Step = b.step("buildlib", "Build the ZenBSD C library");
    const buildlib: *Builder.Step.Run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    buildlib.setCwd(b.path("lib"));
    buildlib_step.dependOn(&buildlib.step);

    // zig build builduserland: run sbin/build.zig, then collect init.
    const builduserland_step: *Builder.Step = b.step("builduserland", "Build the ZenBSD userland");
    const builduserland: *Builder.Step.Run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    builduserland.setCwd(b.path("sbin"));

    const install_init: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(b.path("sbin/zig-out/bin/init"), .bin, "init");
    install_init.step.dependOn(&builduserland.step);
    builduserland_step.dependOn(&install_init.step);

    // zig build iso: run sys' iso target (which builds the kernel) and collect
    // the image.
    const iso_step: *Builder.Step = b.step("iso", "Build a bootable ZenBSD ISO image");
    const iso: *Builder.Step.Run = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "iso" });
    iso.setCwd(b.path("sys"));
    iso.step.dependOn(&install_kernel.step);
    iso.step.dependOn(&install_init.step);

    const install_iso: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(b.path("sys/zig-out/zenbsd.iso"), .{ .custom = "." }, "zenbsd.iso");
    install_iso.step.dependOn(&iso.step);
    iso_step.dependOn(&install_iso.step);

    // zig build run: boot the ISO in QEMU (sys' run target builds it first).
    const run_step: *Builder.Step = b.step("run", "Boot ZenBSD in QEMU");
    const run: *Builder.Step.Run = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "run" });
    run.setCwd(b.path("sys"));
    run.step.dependOn(&builduserland.step);
    run_step.dependOn(&run.step);

    // zig build all
    const all_step: *Builder.Step = b.step("all", "Build the kernel, userland and ISO");
    all_step.dependOn(iso_step);

    // A plain `zig build` builds the kernel and the userland.
    b.default_step.dependOn(buildkernel_step);
    b.default_step.dependOn(builduserland_step);
}
