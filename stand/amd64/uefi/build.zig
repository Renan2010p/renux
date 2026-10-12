// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// stand/amd64/uefi build: the Renux UEFI loader (BOOTX64.EFI).

const std: type = @import("std");
const Builder: type = std.Build;

pub fn build(b: *Builder) void {
    const target: Builder.ResolvedTarget = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
    });

    const mod: *Builder.Module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const exe: *Builder.Step.Compile = b.addExecutable(.{
        .name = "BOOTX64",
        .root_module = mod,
        .use_lld = true,
        .use_llvm = true,
    });

    // Install under the name the firmware looks for.
    const install: *Builder.Step.InstallFile =
        b.addInstallFileWithDir(exe.getEmittedBin(), .{ .custom = "." }, "BOOTX64.EFI");
    b.getInstallStep().dependOn(&install.step);
}
