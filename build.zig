// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The Renux build.
//
// One build for the whole system: the kernel (kernel/), the boot loader
// (bootloader/), the C library and the programs (userland/), the root image,
// the ISO and the QEMU runs. The products land in zig-out/, laid out like the
// installed system:
//
//   zig-out/boot/kernel/kernel   the kernel, with the root image embedded
//   zig-out/boot/loader.efi      the UEFI loader (\EFI\BOOT\BOOTX64.EFI)
//   zig-out/userland/            the native programs, at their system paths
//   zig-out/renux.iso            the bootable ISO
//
// Steps:
//   zig build                    kernel, loader and userland (the default)
//   zig build kernel             the kernel
//   zig build loader             the UEFI loader
//   zig build userland           the native programs
//   zig build fetch              download the FreeBSD userland (base + packages)
//   zig build iso                the bootable UEFI ISO (Zig writer, no xorriso)
//   zig build run                boot the ISO in QEMU (UEFI, serial console)
//   zig build run-efi            boot it through UEFI, in a window
//   zig build test               host unit tests
//
// Options:
//   -Ddevbuild=true              stamp the kernel like a developer build
//   -Dmdroot=false               a kernel without the embedded root image
//
// The FreeBSD userland that runs on Renux is not part of the tree:
// `zig build fetch` (tools/fetch.zig) downloads it, and the root image
// includes it when present.
//
// Everything is Zig: the build runs no shell script and compiles no C. The
// host tools (tools/*.zig) are built for the host and run by the steps below.

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
    const userland_step: *Builder.Step = b.step("userland", "Build the native programs");
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

    // -- root image -----------------------------------------------------------------
    // The userland staged above, plus the FreeBSD userland when fetched, packed
    // into the ext2 image the kernel embeds (FreeBSD's MD_ROOT) by
    // tools/mkrootfs.zig, with the ext2 writer tools/mkfs.zig. The step
    // always runs (the FreeBSD tree is outside the build's knowledge); the
    // image is reproducible, so an unchanged system does not rebuild the
    // kernel.
    const mkfs: *Builder.Module = b.createModule(.{
        .root_source_file = b.path("tools/mkfs.zig"),
        .target = b.graph.host,
    });
    const mkrootfs_tool: *Builder.Step.Compile = hostTool(b, "mkrootfs", mkfs);
    const mkrootfs: *Builder.Step.Run = b.addRunArtifact(mkrootfs_tool);
    mkrootfs.setCwd(b.path("."));
    mkrootfs.addDirectoryArg(stage.getDirectory());
    const root_img: Builder.LazyPath = mkrootfs.addOutputFileArg("root.img");
    mkrootfs.has_side_effects = true;

    // -- kernel ---------------------------------------------------------------------
    const kernel_step: *Builder.Step = b.step("kernel", "Build the kernel");
    const empty_img: Builder.LazyPath = b.addWriteFiles().add("empty.img", "");
    const kernel: *Builder.Step.Compile = buildKernel(b, devbuild, if (mdroot) root_img else empty_img, empty_img);
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

    // -- fetch ----------------------------------------------------------------------
    // Download the FreeBSD userland Renux runs on (base system + packages)
    // with a Zig program: HTTPS, xz/zstd, tar, SHA-256 and the pkg catalog's
    // RSA signature, all from the standard library. No curl, tar, xz, openssl
    // or mtools.
    const fetch_step: *Builder.Step = b.step("fetch", "Download the FreeBSD userland (base + packages)");
    const fetch_tool: *Builder.Step.Compile = b.addExecutable(.{
        .name = "fetch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fetch.zig"),
            .target = b.graph.host,
        }),
    });
    const fetch_run: *Builder.Step.Run = b.addRunArtifact(fetch_tool);
    fetch_run.setCwd(b.path("."));
    fetch_step.dependOn(&fetch_run.step);

    // -- ISO ------------------------------------------------------------------------
    // A UEFI-only ISO, written by tools/mkiso.zig: a FAT16 boot image holding
    // the loader and the kernel, packed into an ISO 9660 volume with an El
    // Torito EFI entry. No xorriso and no mtools: the two formats are written
    // directly, so the medium is made with nothing but Zig and the compiler.
    const iso_step: *Builder.Step = b.step("iso", "Build the Renux UEFI ISO image");
    const mkiso: *Builder.Step.Compile = b.addExecutable(.{
        .name = "mkiso",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkiso.zig"),
            .target = b.graph.host,
        }),
    });
    const mkiso_run: *Builder.Step.Run = b.addRunArtifact(mkiso);
    mkiso_run.addFileArg(kernel.getEmittedBin());
    mkiso_run.addFileArg(loader.getEmittedBin());
    mkiso_run.addFileArg(b.path("bootloader/defaults/loader.conf"));
    const iso: Builder.LazyPath = mkiso_run.addOutputFileArg("renux.iso");
    const install_iso: *Builder.Step.InstallFile = b.addInstallFileWithDir(iso, .prefix, "renux.iso");
    iso_step.dependOn(&install_iso.step);

    // -- installer ISO --------------------------------------------------------------
    // The install medium. Its kernel also carries the ESP image an install
    // writes (the loader, the normal kernel and a loader.conf naming the disk
    // root), exposed as /dev/md1; /dev/md0 is the root image.
    const installer_step: *Builder.Step = b.step("installer-iso", "Build the Renux installer ISO");
    const esp_run: *Builder.Step.Run = b.addRunArtifact(mkiso);
    esp_run.addArg("--fat");
    esp_run.addFileArg(loader.getEmittedBin());
    esp_run.addFileArg(kernel.getEmittedBin());
    esp_run.addFileArg(b.path("bootloader/defaults/loader-installed.conf"));
    const esp_img: Builder.LazyPath = esp_run.addOutputFileArg("esp.img");

    const installer_kernel: *Builder.Step.Compile = buildKernel(b, devbuild, if (mdroot) root_img else empty_img, esp_img);
    const installer_run: *Builder.Step.Run = b.addRunArtifact(mkiso);
    installer_run.addFileArg(installer_kernel.getEmittedBin());
    installer_run.addFileArg(loader.getEmittedBin());
    installer_run.addFileArg(b.path("bootloader/defaults/loader.conf"));
    const installer_iso: Builder.LazyPath = installer_run.addOutputFileArg("renux-installer.iso");
    const install_installer: *Builder.Step.InstallFile = b.addInstallFileWithDir(installer_iso, .prefix, "renux-installer.iso");
    installer_step.dependOn(&install_installer.step);

    // -- QEMU -----------------------------------------------------------------------
    // Both runs boot through UEFI (OVMF) and the Renux loader, the way the
    // ISO does; there is no BIOS/Limine path left.
    const ovmf: []const u8 = b.option([]const u8, "ovmf", "UEFI firmware image for run/run-efi") orelse
        "/usr/share/qemu/edk2-x86_64-code.fd";
    // The persistent disk (disk.img, mounted on /home): made on the first run
    // and then kept, since it holds the user's files.
    const mkdisk: *Builder.Step.Run = b.addRunArtifact(hostTool(b, "mkdisk", mkfs));
    mkdisk.setCwd(b.path("."));
    mkdisk.addArg("disk.img");
    mkdisk.has_side_effects = true;
    const disk: Builder.Step.Run.PathArgOptions = .{ .prefix = "file=", .suffix = ",if=virtio,format=raw" };

    const run_step: *Builder.Step = b.step("run", "Boot Renux in QEMU (UEFI, serial console)");
    const qemu: *Builder.Step.Run = b.addSystemCommand(&.{
        "qemu-system-x86_64", "-M",    "q35",       "-m",   "512M",
        "-drive",             b.fmt("if=pflash,format=raw,readonly=on,file={s}", .{ovmf}),
        "-serial",            "stdio", "-display",  "none", "-no-reboot", "-drive",
    });
    qemu.addFileArg2(b.path("disk.img"), disk);
    qemu.addArg("-cdrom");
    qemu.addFileArg(iso);
    qemu.step.dependOn(&mkdisk.step);
    run_step.dependOn(&qemu.step);

    const run_efi_step: *Builder.Step = b.step("run-efi", "Boot Renux through UEFI and the Renux loader, in a window");
    const qemu_efi: *Builder.Step.Run = b.addSystemCommand(&.{
        "qemu-system-x86_64", "-M",                                                        "q35",     "-m",     "512M",
        "-drive",             b.fmt("if=pflash,format=raw,readonly=on,file={s}", .{ovmf}), "-serial", "stdio",  "-display",
        "gtk",                "-vga",                                                      "virtio",  "-no-reboot", "-drive",
    });
    qemu_efi.addFileArg2(b.path("disk.img"), disk);
    qemu_efi.addArg("-cdrom");
    qemu_efi.addFileArg(iso);
    qemu_efi.step.dependOn(&mkdisk.step);
    run_efi_step.dependOn(&qemu_efi.step);

    // `run-hda` boots the ISO with a real IDE disk on the legacy channel
    // (-M pc), which the kernel drives through the ATA PIO driver as /dev/sda.
    const run_hda_step: *Builder.Step = b.step("run-hda", "Boot Renux in QEMU with an IDE disk (-hda, UEFI, serial)");
    const qemu_hda: *Builder.Step.Run = b.addSystemCommand(&.{
        "qemu-system-x86_64", "-M",       "pc",       "-m",   "512M",
        "-drive",             b.fmt("if=pflash,format=raw,readonly=on,file={s}", .{ovmf}),
        "-serial",            "stdio",    "-display", "none", "-no-reboot", "-hda",
    });
    qemu_hda.addFileArg(b.path("disk.img"));
    qemu_hda.addArg("-cdrom");
    qemu_hda.addFileArg(iso);
    qemu_hda.step.dependOn(&mkdisk.step);
    run_hda_step.dependOn(&qemu_hda.step);

    // -- tests ----------------------------------------------------------------------
    // The pure, portable parts of the kernel, tested on the host.
    const test_step: *Builder.Step = b.step("test", "Run the host unit tests");
    for ([_][]const u8{ "kernel/vm/phys_bitmap.zig", "kernel/core/subr_clock.zig", "kernel/sys/ioccom.zig", "kernel/sys/addr.zig", "kernel/sys/checks.zig" }) |src| {
        const t: *Builder.Step.Compile = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(src),
            .target = b.graph.host,
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}

// -- userland ---------------------------------------------------------------------------

/// A native program: its name, its source (userland/<src>/main.zig) and the
/// directory it is installed in.
const Program: type = struct {
    name: []const u8,
    src: []const u8,
    dest: []const u8,
};

const programs = [_]Program{
    .{ .name = "init", .src = "sbin/init", .dest = "sbin" },
    .{ .name = "renux-installer", .src = "sbin/renux-installer", .dest = "sbin" },
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
    .{ .name = "ls", .src = "bin/ls", .dest = "bin" },
    .{ .name = "wc", .src = "bin/wc", .dest = "bin" },
    .{ .name = "hello", .src = "bin/hello", .dest = "bin" },
    .{ .name = "tui", .src = "bin/tui", .dest = "bin" },
    .{ .name = "nano", .src = "bin/nano", .dest = "bin" },
    .{ .name = "dmesg", .src = "bin/dmesg", .dest = "bin" },
    .{ .name = "logger", .src = "bin/logger", .dest = "usr/bin" },
    .{ .name = "syslogd", .src = "bin/syslogd", .dest = "usr/sbin" },
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

/// The C library and the C startup, the modules every native program imports
/// (as "libc" and "csu").
const Libc: type = struct {
    libc: *Builder.Module,
    csu: *Builder.Module,
};

fn buildLibc(b: *Builder) Libc {
    const libc: *Builder.Module = b.createModule(.{ .root_source_file = b.path("userland/lib/libc/libc.zig") });
    const csu: *Builder.Module = b.createModule(.{ .root_source_file = b.path("userland/lib/csu/csu.zig") });
    csu.addImport("libc", libc);
    return .{ .libc = libc, .csu = csu };
}

/// A native program, linked with the userland linker script.
fn buildProgram(b: *Builder, libc: Libc, optimize: builtin.OptimizeMode, p: Program) *Builder.Step.Compile {
    const mod: *Builder.Module = b.createModule(.{
        .target = userTarget(b),
        .optimize = optimize,
        .root_source_file = b.path(b.fmt("userland/{s}/main.zig", .{p.src})),
        .code_model = .default,
    });
    mod.addImport("libc", libc.libc);
    mod.addImport("csu", libc.csu);
    const exe: *Builder.Step.Compile = b.addExecutable(.{
        .name = p.name,
        .root_module = mod,
        .use_lld = true,
        .use_llvm = true,
    });
    exe.setLinkerScript(b.path("userland/lib/libc/libc.ldscript"));
    return exe;
}

// -- host tools -------------------------------------------------------------------------

/// A program from tools/<name>.zig, built for the host, that imports the ext2
/// writer as "mkfs".
fn hostTool(b: *Builder, name: []const u8, mkfs: *Builder.Module) *Builder.Step.Compile {
    const mod: *Builder.Module = b.createModule(.{
        .root_source_file = b.path(b.fmt("tools/{s}.zig", .{name})),
        .target = b.graph.host,
    });
    mod.addImport("mkfs", mkfs);
    return b.addExecutable(.{ .name = name, .root_module = mod });
}

// -- kernel -----------------------------------------------------------------------------

fn buildKernel(b: *Builder, devbuild: bool, root_img: Builder.LazyPath, esp_img: Builder.LazyPath) *Builder.Step.Compile {
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

    // The boot protocols live with the loader, in bootloader/arch/amd64/.
    const limine: *Builder.Module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("bootloader/arch/amd64/limine/limine.zig"),
    });
    kern.addImport("limine", limine);
    // The Renux boot protocol's kernel side
    // (bootloader/arch/amd64/protocol/kernel.zig) is what the kernel's
    // arch.boot resolves to; its fallback uses the Limine module.
    const boot: *Builder.Module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("bootloader/arch/amd64/protocol/kernel.zig"),
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
    // The installer's ESP image (kernel/fs/espimage.zig); empty unless the
    // build is an installer one.
    kern.addAnonymousImport("espimage", .{ .root_source_file = esp_img });

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

/// The Renux UEFI loader, BOOTX64.EFI. Its modules, and who imports them:
///
///   main      bootloader/efi/main.zig                       the root (with
///                                                           load_elf.zig and
///                                                           handoff.zig)
///   common    bootloader/common/common.zig                  main
///   platform  bootloader/efi/efi_cons.zig                   main, common
///   libefi    bootloader/efi/libefi.zig                     main, platform, loader_md
///   loader_md bootloader/arch/<arch>/efi/md.zig             main
///   bootinfo  bootloader/arch/<arch>/protocol/bootinfo.zig  main
///   gfx_fb    bootloader/common/gfx_fb.zig                  platform
///   font      kernel/dev/wsfont/spleen8x16.zig              gfx_fb (the kernel
///                                                           console's font)
fn buildLoader(b: *Builder) *Builder.Step.Compile {
    const cpu_arch: std.Target.Cpu.Arch = .x86_64;
    const target: Builder.ResolvedTarget = b.resolveTargetQuery(.{ .cpu_arch = cpu_arch, .os_tag = .uefi });
    const arch_dir: []const u8 = switch (cpu_arch) {
        .x86_64 => "bootloader/arch/amd64",
        else => @panic("bootloader: no machine-dependent part for this architecture yet"),
    };

    const loader: Loader = .{ .b = b, .target = target, .optimize = .ReleaseSmall };
    const font: *Builder.Module = loader.module("kernel/dev/wsfont/spleen8x16.zig");
    const gfx_fb: *Builder.Module = loader.module("bootloader/common/gfx_fb.zig");
    const libefi: *Builder.Module = loader.module("bootloader/efi/libefi.zig");
    const platform: *Builder.Module = loader.module("bootloader/efi/efi_cons.zig");
    const common: *Builder.Module = loader.module("bootloader/common/common.zig");
    const bootinfo: *Builder.Module = loader.module(b.fmt("{s}/protocol/bootinfo.zig", .{arch_dir}));
    const md: *Builder.Module = loader.module(b.fmt("{s}/efi/md.zig", .{arch_dir}));
    const main: *Builder.Module = loader.module("bootloader/efi/main.zig");

    gfx_fb.addImport("font", font);
    platform.addImport("gfx_fb", gfx_fb);
    platform.addImport("libefi", libefi);
    common.addImport("platform", platform);
    md.addImport("libefi", libefi);
    main.addImport("platform", platform);
    main.addImport("common", common);
    main.addImport("libefi", libefi);
    main.addImport("loader_md", md);
    main.addImport("bootinfo", bootinfo);

    return b.addExecutable(.{
        .name = "BOOTX64",
        .root_module = main,
        .use_lld = true,
        .use_llvm = true,
    });
}

/// Creates the loader's modules, all for the same target.
const Loader: type = struct {
    b: *Builder,
    target: Builder.ResolvedTarget,
    optimize: builtin.OptimizeMode,

    fn module(l: Loader, path: []const u8) *Builder.Module {
        return l.b.createModule(.{
            .root_source_file = l.b.path(path),
            .target = l.target,
            .optimize = l.optimize,
        });
    }
};
