// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// stand/efi/loader build: the Renux UEFI loader (BOOTX64.EFI).

const std: type = @import("std");
const Builder: type = std.Build;

pub fn build(b: *Builder) void {
    const target: Builder.ResolvedTarget = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
    });
    const optimize: std.builtin.OptimizeMode = .ReleaseSmall;

    // The kernel console's font, so loader and kernel text look the same.
    const font_mod: *Builder.Module = b.createModule(.{
        .root_source_file = b.path("../../../kernel/dev/wsfont/spleen8x16.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The loader's own framebuffer text console (stand/common/gfx_fb.zig).
    const gfx_mod: *Builder.Module = b.createModule(.{
        .root_source_file = b.path("../../common/gfx_fb.zig"),
        .target = target,
        .optimize = optimize,
    });
    gfx_mod.addImport("font", font_mod);

    // The firmware services the machine-independent loader runs on.
    const platform_mod: *Builder.Module = b.createModule(.{
        .root_source_file = b.path("efi_cons.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_mod.addImport("gfx_fb", gfx_mod);

    // The machine-independent loader (stand/common).
    const common_mod: *Builder.Module = b.createModule(.{
        .root_source_file = b.path("../../common/common.zig"),
        .target = target,
        .optimize = optimize,
    });
    common_mod.addImport("platform", platform_mod);

    // The boot protocol types, shared with the kernel.
    const bootinfo_mod: *Builder.Module = b.createModule(.{
        .root_source_file = b.path("../../arch/amd64/bootinfo.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod: *Builder.Module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The machine-dependent part (FreeBSD's stand/efi/loader/arch/<machine>).
    const md_mod: *Builder.Module = b.createModule(.{
        .root_source_file = b.path(switch (target.result.cpu.arch) {
            .x86_64 => "arch/amd64/md.zig",
            else => @panic("stand/efi/loader: no machine-dependent part for this architecture yet"),
        }),
        .target = target,
        .optimize = optimize,
    });

    mod.addImport("platform", platform_mod);
    mod.addImport("common", common_mod);
    mod.addImport("loader_md", md_mod);
    mod.addImport("bootinfo", bootinfo_mod);

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
