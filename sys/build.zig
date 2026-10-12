// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project

const std: type = @import("std");
const builtin: type = std.builtin;
const Target: type = std.Target;
const Query: type = Target.Query;
const Builder: type = std.Build;

pub fn build(b: *Builder) !void {
    const query: Query = Query{
        .cpu_arch = b.graph.host.query.cpu_arch,
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
    };

    const target: Builder.ResolvedTarget = b.resolveTargetQuery(query);

    const optimize: builtin.OptimizeMode = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .fast,
    });

    const kern_mod: *Builder.Module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("sys_root.zig"),
        .code_model = .kernel,
        .pic = false,
        .red_zone = false,
        .strip = false,
    });

    // Boot protocol bindings live in stand/, outside sys/, so they are added as
    // an importable module rather than a relative import.
    const limine_mod: *Builder.Module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("../stand/amd64/limine/limine.zig"),
    });
    kern_mod.addImport("limine", limine_mod);

    // The Renux boot protocol (stand/arch/amd64/boot.zig). It is what the
    // kernel's arch.boot resolves to; its own fallback uses the Limine module.
    const boot_mod: *Builder.Module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("../stand/arch/amd64/boot.zig"),
    });
    boot_mod.addImport("limine", limine_mod);
    kern_mod.addImport("renuxboot", boot_mod);

    const kern_exec: *Builder.Step.Compile = b.addExecutable(.{
        .name = "kernel",
        .root_module = kern_mod,
        .use_lld = true,
        .use_llvm = true,
    });

    // Architecture-specific linker script. amd64 is the only port so far; once
    // more ports exist this should be selected from the target CPU arch.
    kern_exec.setLinkerScript(b.path("arch/amd64/conf/kern.ldscript"));

    // The root filesystem image is embedded in the kernel (FreeBSD's MD_ROOT,
    // see fs/rootimage.zig). The top-level build generates the real image at
    // sys/root.img; a standalone build here gets an empty one and boots from
    // the boot modules instead.
    const ensure_root: *Builder.Step.Run = b.addSystemCommand(&.{ "sh", "-c", "[ -f root.img ] || : > root.img" });
    kern_exec.step.dependOn(&ensure_root.step);

    const install_kernel: *Builder.Step.InstallArtifact = b.addInstallArtifact(kern_exec, .{});

    b.getInstallStep().dependOn(&install_kernel.step);

    // `zig build iso` -> bootable hybrid BIOS/UEFI ISO image.
    const iso_step: *Builder.Step = b.step("iso", "Build a bootable Renux ISO image");

    const mkiso: *Builder.Step.Run = b.addSystemCommand(&.{ "sh", "../tools/mkiso.sh" });

    mkiso.step.dependOn(&install_kernel.step);

    iso_step.dependOn(&mkiso.step);

    // `zig build run` -> boot the ISO in QEMU (BIOS, serial on stdio).
    const run_step: *Builder.Step = b.step("run", "Boot Renux in QEMU (BIOS)");

    const qemu: *Builder.Step.Run = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-M",
        "q35",
        "-m",
        "512M",
        "-cdrom",
        "zig-out/renux.iso",
        "-boot",
        "d",
        "-serial",
        "stdio",
        "-display",
        "none",
        "-no-reboot",
    });

    qemu.step.dependOn(iso_step);

    run_step.dependOn(&qemu.step);
}
