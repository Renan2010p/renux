// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The Renux build.
//
// One build for the whole system: the kernel (kernel/), the boot loader
// (stand/), the C library and the programs (userland/), the root image, the
// ISO and the QEMU runs. The products land in zig-out/, laid out like the
// installed system:
//
//   zig-out/boot/kernel/kernel   the kernel, with the root image embedded
//   zig-out/boot/loader.efi      the UEFI loader (\EFI\BOOT\BOOTX64.EFI)
//   zig-out/userland/            the native programs, at their system paths
//   zig-out/lib/libc.a           the C library (for tools/zcc)
//   zig-out/renux.iso            the bootable ISO
//
// Steps:
//   zig build                    kernel, loader and userland (the default)
//   zig build kernel             the kernel
//   zig build loader             the UEFI loader
//   zig build userland           the C library and the native programs
//   zig build iso                the bootable ISO (UEFI: Renux loader, BIOS: Limine)
//   zig build run                boot the ISO in QEMU (serial console)
//   zig build run-efi            boot it through UEFI, in a window
//   zig build test               host unit tests
//
// Options:
//   -Ddevbuild=true              stamp the kernel like a developer build
//   -Dmdroot=false               a kernel without the embedded root image
//
// The FreeBSD userland that runs on Renux is not part of the tree:
// tools/get-freebsd.sh and tools/get-freebsd-pkg.sh fetch it, and the root
// image includes it when present.

const std: type = @import("std");
const builtin: type = std.builtin;
const Builder: type = std.Build;

pub fn build(b: *Builder) void {
    const devbuild: bool = b.option(bool, "devbuild", "Stamp the kernel with the build date, user and host") orelse false;
    const mdroot: bool = b.option(bool, "mdroot", "Embed the root image in the kernel (MD_ROOT)") orelse true;
    const optimize: builtin.OptimizeMode = b.standardOptimizeOption(.{ .preferred_optimize_mode = .fast });

    // -- userland -------------------------------------------------------------------
    // The programs are staged in a tree laid out like the installed system,
    // which the root image is made from and which is installed as
    // zig-out/userland.
    const userland_step: *Builder.Step = b.step("userland", "Build the C library and the native programs");
    const libc: Libc = buildLibc(b);
    const stage: *Builder.Step.WriteFile = b.addWriteFiles();
    for (programs) |p| {
        const exe: *Builder.Step.Compile = buildProgram(b, libc, optimize, p);
        _ = stage.addCopyFile(exe.getEmittedBin(), b.fmt("{s}/{s}", .{ p.dest, p.name }));
    }
    const install_userland: *Builder.Step.InstallDir = b.addInstallDirectory(.{
        .source_dir = stage.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "userland",
    });
    userland_step.dependOn(&install_userland.step);
    userland_step.dependOn(&b.addInstallArtifact(libc.archive, .{}).step);

    // -- root image -----------------------------------------------------------------
    // The userland staged above, plus the FreeBSD userland when fetched, packed
    // into the ext2 image the kernel embeds (FreeBSD's MD_ROOT). The script
    // always runs (the FreeBSD tree is outside the build's knowledge); the
    // image is reproducible, so an unchanged system does not rebuild the
    // kernel.
    const mkrootfs: *Builder.Step.Run = b.addSystemCommand(&.{ "sh", "tools/mkrootfs.sh" });
    mkrootfs.setCwd(b.path("."));
    mkrootfs.addDirectoryArg(stage.getDirectory());
    const root_img: Builder.LazyPath = mkrootfs.addOutputFileArg("root.img");
    mkrootfs.has_side_effects = true;

    // -- kernel ---------------------------------------------------------------------
    const kernel_step: *Builder.Step = b.step("kernel", "Build the kernel");
    const empty_img: Builder.LazyPath = b.addWriteFiles().add("empty.img", "");
    const kernel: *Builder.Step.Compile = buildKernel(b, devbuild, if (mdroot) root_img else empty_img);
    const install_kernel: *Builder.Step.InstallFile = b.addInstallFileWithDir(kernel.getEmittedBin(), .{ .custom = "boot/kernel" }, "kernel");
    kernel_step.dependOn(&install_kernel.step);

    // -- loader ---------------------------------------------------------------------
    const loader_step: *Builder.Step = b.step("loader", "Build the UEFI boot loader");
    const loader: *Builder.Step.Compile = buildLoader(b);
    const install_loader: *Builder.Step.InstallFile = b.addInstallFileWithDir(loader.getEmittedBin(), .{ .custom = "boot" }, "loader.efi");
    loader_step.dependOn(&install_loader.step);

    b.getInstallStep().dependOn(kernel_step);
    b.getInstallStep().dependOn(loader_step);
    b.getInstallStep().dependOn(userland_step);

    // -- ISO ------------------------------------------------------------------------
    const iso_step: *Builder.Step = b.step("iso", "Build a bootable Renux ISO image");
    const mkiso: *Builder.Step.Run = b.addSystemCommand(&.{ "sh", "tools/mkiso.sh" });
    mkiso.setCwd(b.path("."));
    mkiso.addFileArg(kernel.getEmittedBin());
    mkiso.addFileArg(loader.getEmittedBin());
    const iso: Builder.LazyPath = mkiso.addOutputFileArg("renux.iso");
    const install_iso: *Builder.Step.InstallFile = b.addInstallFileWithDir(iso, .prefix, "renux.iso");
    iso_step.dependOn(&install_iso.step);

    // -- QEMU -----------------------------------------------------------------------
    // The persistent disk (disk.img, mounted on /home): made on the first run
    // and then kept, since it holds the user's files.
    const mkdisk: *Builder.Step.Run = b.addSystemCommand(&.{ "sh", "tools/mkdisk.sh", "disk.img" });
    mkdisk.setCwd(b.path("."));
    mkdisk.has_side_effects = true;
    const disk: Builder.Step.Run.PathArgOptions = .{ .prefix = "file=", .suffix = ",if=virtio,format=raw" };

    const run_step: *Builder.Step = b.step("run", "Boot Renux in QEMU (serial console)");
    const qemu: *Builder.Step.Run = b.addSystemCommand(&.{
        "qemu-system-x86_64", "-M",       "q35",  "-m",         "512M", "-boot", "d",
        "-serial",            "stdio",    "-display", "none", "-no-reboot", "-drive",
    });
    qemu.addFileArg2(b.path("disk.img"), disk);
    qemu.addArg("-cdrom");
    qemu.addFileArg(iso);
    qemu.step.dependOn(&mkdisk.step);
    run_step.dependOn(&qemu.step);

    const run_efi_step: *Builder.Step = b.step("run-efi", "Boot Renux through UEFI and the Renux loader, in a window");
    const ovmf: []const u8 = b.option([]const u8, "ovmf", "UEFI firmware image for run-efi") orelse
        "/usr/share/qemu/edk2-x86_64-code.fd";
    const qemu_efi: *Builder.Step.Run = b.addSystemCommand(&.{
        "qemu-system-x86_64", "-M",      "q35",   "-m",        "512M",
        "-drive",             b.fmt("if=pflash,format=raw,readonly=on,file={s}", .{ovmf}),
        "-serial",            "stdio",   "-display", "gtk",     "-drive",
    });
    qemu_efi.addFileArg2(b.path("disk.img"), disk);
    qemu_efi.addArg("-cdrom");
    qemu_efi.addFileArg(iso);
    qemu_efi.step.dependOn(&mkdisk.step);
    run_efi_step.dependOn(&qemu_efi.step);

    // -- tests ----------------------------------------------------------------------
    // The pure, portable parts of the kernel, tested on the host.
    const test_step: *Builder.Step = b.step("test", "Run the host unit tests");
    for ([_][]const u8{ "kernel/vm/phys_bitmap.zig", "kernel/core/subr_clock.zig", "kernel/sys/ioccom.zig" }) |src| {
        const t: *Builder.Step.Compile = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(src),
            .target = b.graph.host,
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}

// -- userland ---------------------------------------------------------------------------

/// A native program: its name, its source (userland/<src>/main.zig, plus
/// main.c for the ones written in C) and where it is installed.
const Program: type = struct {
    name: []const u8,
    src: []const u8,
    dest: []const u8,
    c: bool = false,
};

const programs = [_]Program{
    .{ .name = "init", .src = "sbin/init", .dest = "sbin" },
    .{ .name = "getty", .src = "libexec/getty", .dest = "usr/libexec" },
    .{ .name = "login", .src = "usr/bin/login", .dest = "usr/bin" },
    .{ .name = "stat", .src = "usr/bin/stat", .dest = "usr/bin" },
    .{ .name = "sh", .src = "bin/sh", .dest = "bin" },
    .{ .name = "cat", .src = "bin/cat", .dest = "bin" },
    .{ .name = "echo", .src = "bin/echo", .dest = "bin" },
    .{ .name = "pwd", .src = "bin/pwd", .dest = "bin" },
    .{ .name = "mkdir", .src = "bin/mkdir", .dest = "bin" },
    .{ .name = "rm", .src = "bin/rm", .dest = "bin" },
    .{ .name = "rmdir", .src = "bin/rmdir", .dest = "bin" },
    .{ .name = "fbdraw", .src = "bin/fbdraw", .dest = "bin" },
    .{ .name = "ls", .src = "bin/ls", .dest = "bin", .c = true },
    .{ .name = "wc", .src = "bin/wc", .dest = "bin", .c = true },
    .{ .name = "hello", .src = "bin/hello", .dest = "bin", .c = true },
    .{ .name = "tui", .src = "bin/tui", .dest = "bin", .c = true },
    .{ .name = "nano", .src = "bin/nano", .dest = "bin", .c = true },
    .{ .name = "dmesg", .src = "bin/dmesg", .dest = "bin", .c = true },
    .{ .name = "logger", .src = "bin/logger", .dest = "usr/bin", .c = true },
    .{ .name = "syslogd", .src = "bin/syslogd", .dest = "usr/sbin", .c = true },
};

/// The user-mode target: freestanding (Renux's own C library and startup).
fn userTarget(b: *Builder) Builder.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = b.graph.host.query.cpu_arch,
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
    });
}

const Libc: type = struct {
    libc: *Builder.Module,
    csu: *Builder.Module,
    archive: *Builder.Step.Compile,
};

/// The C library: the `libc` and `csu` modules native programs import, and
/// libc.a for C programs built with tools/zcc.
fn buildLibc(b: *Builder) Libc {
    const libc: *Builder.Module = b.createModule(.{ .root_source_file = b.path("userland/lib/libc/libc.zig") });
    const csu: *Builder.Module = b.createModule(.{ .root_source_file = b.path("userland/lib/csu/csu.zig") });
    csu.addImport("libc", libc);

    const renux: *Builder.Module = b.createModule(.{
        .target = userTarget(b),
        .optimize = .ReleaseSmall,
        .root_source_file = b.path("userland/lib/renux.zig"),
    });
    renux.addImport("libc", libc);
    renux.addImport("csu", csu);
    const archive: *Builder.Step.Compile = b.addLibrary(.{ .name = "c", .root_module = renux, .linkage = .static });
    return .{ .libc = libc, .csu = csu, .archive = archive };
}

fn buildProgram(b: *Builder, libc: Libc, optimize: builtin.OptimizeMode, p: Program) *Builder.Step.Compile {
    const mod: *Builder.Module = b.createModule(.{
        .target = userTarget(b),
        .optimize = optimize,
        .root_source_file = b.path(b.fmt("userland/{s}/main.zig", .{p.src})),
        .code_model = .default,
    });
    mod.addImport("libc", libc.libc);
    mod.addImport("csu", libc.csu);
    if (p.c) {
        mod.addIncludePath(b.path("userland/lib/include"));
        mod.addCSourceFile(.{ .file = b.path(b.fmt("userland/{s}/main.c", .{p.src})), .flags = &.{} });
    }
    const exe: *Builder.Step.Compile = b.addExecutable(.{
        .name = p.name,
        .root_module = mod,
        .use_lld = true,
        .use_llvm = true,
    });
    exe.setLinkerScript(b.path("userland/lib/libc/libc.ldscript"));
    return exe;
}

// -- kernel -----------------------------------------------------------------------------

fn buildKernel(b: *Builder, devbuild: bool, root_img: Builder.LazyPath) *Builder.Step.Compile {
    const cpu_arch: std.Target.Cpu.Arch = b.graph.host.query.cpu_arch orelse b.graph.host.result.cpu.arch;
    const target: Builder.ResolvedTarget = b.resolveTargetQuery(.{
        .cpu_arch = cpu_arch,
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
        .cpu_features_sub = kernFeaturesSub(cpu_arch),
        .cpu_features_add = kernFeaturesAdd(cpu_arch),
    });

    // The kernel is always built ReleaseFast: a debug kernel is many times
    // slower (the console, the scheduler and every system call) and needs far
    // deeper kernel stacks. Debug output does not depend on it: boot -v and
    // truss=<comm> work in the optimized kernel.
    const optimize: builtin.OptimizeMode = .ReleaseFast;

    const kern: *Builder.Module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("kernel/sys_root.zig"),
        .code_model = .kernel,
        .pic = false,
        .red_zone = false,
        .strip = false,
    });

    // Boot protocol bindings live in stand/ and are shared with the loader.
    const limine: *Builder.Module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("stand/amd64/limine/limine.zig"),
    });
    kern.addImport("limine", limine);
    // The Renux boot protocol (stand/arch/amd64/boot.zig) is what the kernel's
    // arch.boot resolves to; its fallback uses the Limine module.
    const boot: *Builder.Module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("stand/arch/amd64/boot.zig"),
    });
    boot.addImport("limine", limine);
    kern.addImport("renuxboot", boot);

    // Kernel identification (the role of FreeBSD's sys/conf/newvers.sh): the
    // release, the source revision and its date, as the `vers` module. The
    // date is the commit's, not the build's, so the same tree builds the same
    // kernel; -Ddevbuild=true stamps it like a FreeBSD developer kernel.
    kern.addImport("vers", newvers(b, devbuild).createModule());

    // The root image the kernel carries (kernel/fs/rootimage.zig).
    kern.addAnonymousImport("rootimage", .{ .root_source_file = root_img });

    const exe: *Builder.Step.Compile = b.addExecutable(.{
        .name = "kernel",
        .root_module = kern,
        .use_lld = true,
        .use_llvm = true,
    });
    // compiler_rt cannot be built without SIMD (its float routines take SSE
    // arguments); the kernel supplies the memory routines it needs itself
    // (core/subr_libkern.zig), as FreeBSD's libkern does.
    exe.bundle_compiler_rt = false;
    // amd64 is the only port so far; with more, the script follows the arch.
    exe.setLinkerScript(b.path("kernel/arch/amd64/conf/kern.ldscript"));
    return exe;
}

// Per-architecture kernel code generation, as FreeBSD's sys/conf/kern.mk
// selects CFLAGS by MACHINE_CPUARCH.
//
// No SIMD or floating point in the kernel (FreeBSD's amd64 kernel is built
// with -mno-mmx -mno-sse -msoft-float -mno-avx): the user's MMX/SSE/AVX
// registers are only saved when a process gives up the CPU, so kernel code
// that used them (an optimised memcpy, a vectorised loop) would corrupt the
// interrupted program's registers. x87 stays enabled only because
// compiler_rt's long double functions need it; the kernel has no
// floating-point code, so none is ever emitted.

fn kernFeaturesSub(cpu_arch: std.Target.Cpu.Arch) std.Target.Cpu.Feature.Set {
    return switch (cpu_arch) {
        .x86_64 => std.Target.x86.featureSet(&.{ .mmx, .sse, .sse2, .sse3, .ssse3, .sse4_1, .sse4_2, .avx, .avx2, .avx512f }),
        else => @panic("build.zig: no kernel code generation flags for this architecture yet"),
    };
}

fn kernFeaturesAdd(cpu_arch: std.Target.Cpu.Arch) std.Target.Cpu.Feature.Set {
    return switch (cpu_arch) {
        .x86_64 => std.Target.x86.featureSet(&.{.soft_float}),
        else => @panic("build.zig: no kernel code generation flags for this architecture yet"),
    };
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

// -- loader -----------------------------------------------------------------------------

/// The Renux UEFI loader (stand/efi/loader): the MI loader (stand/common),
/// the UEFI console and the console font it shares with the kernel.
fn buildLoader(b: *Builder) *Builder.Step.Compile {
    const target: Builder.ResolvedTarget = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .uefi });
    const optimize: builtin.OptimizeMode = .ReleaseSmall;
    const opts = .{ .target = target, .optimize = optimize };

    const font: *Builder.Module = b.createModule(.{ .root_source_file = b.path("kernel/dev/wsfont/spleen8x16.zig"), .target = opts.target, .optimize = opts.optimize });
    const gfx: *Builder.Module = b.createModule(.{ .root_source_file = b.path("stand/common/gfx_fb.zig"), .target = opts.target, .optimize = opts.optimize });
    gfx.addImport("font", font);
    const platform: *Builder.Module = b.createModule(.{ .root_source_file = b.path("stand/efi/loader/efi_cons.zig"), .target = opts.target, .optimize = opts.optimize });
    platform.addImport("gfx_fb", gfx);
    const common: *Builder.Module = b.createModule(.{ .root_source_file = b.path("stand/common/common.zig"), .target = opts.target, .optimize = opts.optimize });
    common.addImport("platform", platform);
    const bootinfo: *Builder.Module = b.createModule(.{ .root_source_file = b.path("stand/arch/amd64/bootinfo.zig"), .target = opts.target, .optimize = opts.optimize });
    const md: *Builder.Module = b.createModule(.{
        .root_source_file = b.path(switch (target.result.cpu.arch) {
            .x86_64 => "stand/efi/loader/arch/amd64/md.zig",
            else => @panic("stand/efi/loader: no machine-dependent part for this architecture yet"),
        }),
        .target = opts.target,
        .optimize = opts.optimize,
    });

    const mod: *Builder.Module = b.createModule(.{ .root_source_file = b.path("stand/efi/loader/main.zig"), .target = opts.target, .optimize = opts.optimize });
    mod.addImport("platform", platform);
    mod.addImport("common", common);
    mod.addImport("loader_md", md);
    mod.addImport("bootinfo", bootinfo);

    return b.addExecutable(.{
        .name = "BOOTX64",
        .root_module = mod,
        .use_lld = true,
        .use_llvm = true,
    });
}
