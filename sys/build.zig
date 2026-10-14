// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project

const std: type = @import("std");
const builtin: type = std.builtin;
const Target: type = std.Target;
const Query: type = Target.Query;
const Builder: type = std.Build;

pub fn build(b: *Builder) !void {
    const cpu_arch: std.Target.Cpu.Arch = b.graph.host.query.cpu_arch orelse b.graph.host.result.cpu.arch;
    const query: Query = Query{
        .cpu_arch = cpu_arch,
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
        .cpu_features_sub = kernFeaturesSub(cpu_arch),
        .cpu_features_add = kernFeaturesAdd(cpu_arch),
    };

    const target: Builder.ResolvedTarget = b.resolveTargetQuery(query);

    // The kernel is always built ReleaseFast: a debug kernel is many times
    // slower (the console, the scheduler and every system call) and needs far
    // deeper kernel stacks. Debug output does not depend on it: boot -v and
    // truss=<comm> work in the optimized kernel.
    const optimize: builtin.OptimizeMode = .ReleaseFast;

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

    // Kernel identification (the role of FreeBSD's sys/conf/newvers.sh): the
    // release, the source revision and its date, as the `vers` module. The date
    // is the commit's, not the build's, so the same tree builds the same kernel.
    // -Ddevbuild=true stamps the build like a FreeBSD developer kernel (build
    // date, user@host:path); the default is the reproducible release form.
    const devbuild: bool = b.option(bool, "devbuild", "Stamp the kernel with the build date, user and host") orelse false;
    kern_mod.addImport("vers", newvers(b, devbuild).createModule());

    const kern_exec: *Builder.Step.Compile = b.addExecutable(.{
        .name = "kernel",
        .root_module = kern_mod,
        .use_lld = true,
        .use_llvm = true,
    });
    // compiler_rt cannot be built without SIMD (its float routines take SSE
    // arguments); the kernel supplies the memory routines it needs itself
    // (kern/subr_libkern.zig), as FreeBSD's libkern does.
    kern_exec.bundle_compiler_rt = false;

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

    // The persistent disk (sys/disk.img, mounted on /home): created on the
    // first run, then kept, since it holds the user's files.
    const ensure_disk: *Builder.Step.Run = b.addSystemCommand(&.{ "sh", "../tools/mkdisk.sh", "disk.img" });

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
        "-drive",
        "file=disk.img,if=virtio,format=raw",
    });

    qemu.step.dependOn(iso_step);
    qemu.step.dependOn(&ensure_disk.step);

    run_step.dependOn(&qemu.step);

    // `zig build run-efi` -> boot the ISO through UEFI (OVMF) and the Renux
    // loader, in a graphical window (GTK: works on Wayland and X11), with the
    // serial console on stdio as well.
    const run_efi_step: *Builder.Step = b.step("run-efi", "Boot Renux in QEMU (UEFI, graphical window)");
    const ovmf: []const u8 = b.option([]const u8, "ovmf", "UEFI firmware image for run-efi") orelse
        "/usr/share/qemu/edk2-x86_64-code.fd";
    const qemu_efi: *Builder.Step.Run = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-M",
        "q35",
        "-m",
        "512M",
        "-drive",
        b.fmt("if=pflash,format=raw,readonly=on,file={s}", .{ovmf}),
        "-cdrom",
        "zig-out/renux.iso",
        "-drive",
        "file=disk.img,if=virtio,format=raw",
        "-serial",
        "stdio",
        "-display",
        "gtk",
    });
    qemu_efi.step.dependOn(iso_step);
    qemu_efi.step.dependOn(&ensure_disk.step);
    run_efi_step.dependOn(&qemu_efi.step);
}

/// Release name and branch, as FreeBSD's REVISION and BRANCH.
const REVISION: []const u8 = "0.1";
const BRANCH: []const u8 = "CURRENT";

/// Run a command and return its trimmed output, or null when it fails.
fn runOut(b: *Builder, argv: []const []const u8) ?[]const u8 {
    return switch (b.runFallible(argv, .{ .stderr_behavior = .ignore })) {
        .success => |out| std.mem.trim(u8, out, " \t\r\n"),
        else => null,
    };
}

/// Run `git` in the source tree and return its trimmed output, or null when
/// the tree is not a git checkout (a release tarball).
fn git(b: *Builder, args: []const []const u8) ?[]const u8 {
    var argv: [8][]const u8 = undefined;
    argv[0] = "git";
    for (args, 0..) |a, i| {
        argv[1 + i] = a;
    }
    return runOut(b, argv[0 .. 1 + args.len]);
}

/// Collect the kernel identification into a build options module, as
/// FreeBSD's newvers.sh does. The reproducible form carries only the release
/// and the source revision; a developer build adds the build time and
/// user@host:path.
fn newvers(b: *Builder, devbuild: bool) *Builder.Step.Options {
    const opts: *Builder.Step.Options = b.addOptions();

    // FreeBSD-style revision string: <branch>-n<commit count>-<hash>[-dirty].
    var revision: []const u8 = "unknown";
    var commit_time: i64 = 0;
    if (git(b, &.{ "rev-parse", "--short=12", "HEAD" })) |hash| {
        const branch: []const u8 = git(b, &.{ "rev-parse", "--abbrev-ref", "HEAD" }) orelse "HEAD";
        const count: []const u8 = git(b, &.{ "rev-list", "--count", "HEAD" }) orelse "0";
        const status: []const u8 = git(b, &.{ "status", "--porcelain", "--untracked-files=no" }) orelse "";
        revision = b.fmt("{s}-n{s}-{s}{s}", .{ branch, count, hash, if (status.len > 0) "-dirty" else "" });
        if (git(b, &.{ "log", "-1", "--format=%ct" })) |ct| {
            commit_time = std.fmt.parseInt(i64, ct, 10) catch 0;
        }
    }

    opts.addOption([]const u8, "revision", REVISION);
    opts.addOption([]const u8, "branch", BRANCH);
    opts.addOption([]const u8, "source", revision);
    opts.addOption(i64, "time", commit_time);
    opts.addOption([]const u8, "ident", "GENERIC");

    opts.addOption(bool, "devbuild", devbuild);
    var build_time: i64 = 0;
    var who: []const u8 = "";
    if (devbuild) {
        build_time = std.fmt.parseInt(i64, runOut(b, &.{ "date", "+%s" }) orelse "0", 10) catch 0;
        const user: []const u8 = runOut(b, &.{ "id", "-un" }) orelse "root";
        const host: []const u8 = runOut(b, &.{ "uname", "-n" }) orelse "localhost";
        const dir: []const u8 = runOut(b, &.{"pwd"}) orelse ".";
        who = b.fmt("{s}@{s}:{s}", .{ user, host, dir });
    }
    opts.addOption(i64, "build_time", build_time);
    opts.addOption([]const u8, "builder", who);
    return opts;
}

// Per-architecture kernel code generation, as FreeBSD's sys/conf/kern.mk
// selects CFLAGS by MACHINE_CPUARCH.
//
// No SIMD or floating point in the kernel (FreeBSD's amd64 kernel is built
// with -mno-mmx -mno-sse -msoft-float -mno-avx): system calls and interrupts
// do not save the user's MMX/SSE/AVX registers, so kernel code that used
// them (an optimised memcpy, a vectorised loop) would corrupt the
// interrupted program's registers, and a page fault taken in the middle of a
// vectorised copy would clobber the copy itself. x87 stays enabled only
// because compiler_rt's long double functions need it; the kernel has no
// floating-point code, so none is ever emitted.

fn kernFeaturesSub(cpu_arch: std.Target.Cpu.Arch) std.Target.Cpu.Feature.Set {
    return switch (cpu_arch) {
        .x86_64 => std.Target.x86.featureSet(&.{ .mmx, .sse, .sse2, .sse3, .ssse3, .sse4_1, .sse4_2, .avx, .avx2, .avx512f }),
        else => @panic("sys/build.zig: no kernel code generation flags for this architecture yet"),
    };
}

fn kernFeaturesAdd(cpu_arch: std.Target.Cpu.Arch) std.Target.Cpu.Feature.Set {
    return switch (cpu_arch) {
        .x86_64 => std.Target.x86.featureSet(&.{.soft_float}),
        else => @panic("sys/build.zig: no kernel code generation flags for this architecture yet"),
    };
}
