// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Top-level build.
//
// The kernel (sys/) and the userland (sbin/) each have their own build.zig.
// This file is the entry point at the root of the tree, so the common targets
// can be driven from here:
//
//   zig build buildkernel    build the kernel
//   zig build builduserland  build the userland
//   zig build iso            build a bootable ISO (kernel + userland)
//   zig build run            boot the ISO in QEMU
//   zig build all            build kernel, userland and ISO

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
    buildkernel_step.dependOn(&buildkernel.step);

    // zig build builduserland
    const builduserland_step: *Builder.Step = b.step("builduserland", "Build the ZenBSD userland");
    const builduserland: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build" });
    builduserland.setCwd(b.path("sbin"));
    builduserland_step.dependOn(&builduserland.step);

    // zig build iso
    const iso_step: *Builder.Step = b.step("iso", "Build a bootable ZenBSD ISO image");
    const iso: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build", "iso" });
    iso.setCwd(b.path("sys"));
    iso.step.dependOn(&builduserland.step);
    iso_step.dependOn(&iso.step);

    // zig build run
    const run_step: *Builder.Step = b.step("run", "Boot ZenBSD in QEMU");
    const run: *Builder.Step.Run = b.addSystemCommand(&.{ zig(b), "build", "run" });
    run.setCwd(b.path("sys"));
    run.step.dependOn(&builduserland.step);
    run_step.dependOn(&run.step);

    // zig build all
    const all_step: *Builder.Step = b.step("all", "Build the kernel, userland and ISO");
    all_step.dependOn(&iso.step);

    // A plain `zig build` builds the kernel and the userland.
    b.default_step.dependOn(&buildkernel.step);
    b.default_step.dependOn(&builduserland.step);
}
