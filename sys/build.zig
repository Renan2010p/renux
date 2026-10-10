// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project

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
        .root_source_file = b.path("index.zig"),
        .code_model = .kernel,
        .pic = false,
        .red_zone = false,
        .strip = false,
    });

    const kern_exec: *Builder.Step.Compile = b.addExecutable(.{
        .name = "kernel",
        .root_module = kern_mod,
        .use_lld = true,
        .use_llvm = true,
    });

    // Architecture-specific linker script. amd64 is the only port so far; once
    // more ports exist this should be selected from the target CPU arch.
    kern_exec.setLinkerScript(b.path("arch/amd64/conf/kern.ldscript"));

    const install_kernel = b.addInstallArtifact(kern_exec, .{});
    b.getInstallStep().dependOn(&install_kernel.step);

    // `zig build iso` -> bootable hybrid BIOS/UEFI ISO image.
    const iso_step = b.step("iso", "Build a bootable ZenBSD ISO image");
    const mkiso = b.addSystemCommand(&.{ "sh", "stand/amd64/limine/mkiso.sh" });
    mkiso.step.dependOn(&install_kernel.step);
    iso_step.dependOn(&mkiso.step);

    // `zig build run` -> boot the ISO in QEMU (BIOS, serial on stdio).
    const run_step = b.step("run", "Boot ZenBSD in QEMU (BIOS)");
    const qemu = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-M",
        "q35",
        "-m",
        "512M",
        "-cdrom",
        "zig-out/zenbsd.iso",
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
