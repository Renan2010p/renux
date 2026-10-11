// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// C library build definition.
//
// Exposes the library as a module named "libc" (and the startup as "csu") that
// userland programs import by name, and also builds a standalone static
// library libc.a, for cross-compiling C programs against the headers in
// include/ (see tools/mksysroot.sh and tools/zcc).

const std: type = @import("std");
const Builder: type = std.Build;
const builtin: type = std.builtin;

pub fn build(b: *Builder) !void {
    const libc_mod: *Builder.Module = b.addModule("libc", .{
        .root_source_file = b.path("libc/libc.zig"),
    });
    // The C startup lives in lib/csu, as in NetBSD/FreeBSD, and depends on the
    // C library for exit().
    const csu_mod: *Builder.Module = b.addModule("csu", .{
        .root_source_file = b.path("csu/csu.zig"),
    });
    csu_mod.addImport("libc", libc_mod);

    // The standalone static library, for C programs compiled with zig cc.
    const target: Builder.ResolvedTarget = b.resolveTargetQuery(.{
        .cpu_arch = b.graph.host.query.cpu_arch,
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
    });
    const renux_mod: *Builder.Module = b.createModule(.{
        .target = target,
        .optimize = builtin.OptimizeMode.ReleaseSmall,
        .root_source_file = b.path("renux.zig"),
    });
    renux_mod.addImport("libc", libc_mod);
    renux_mod.addImport("csu", csu_mod);
    const libc_a: *Builder.Step.Compile = b.addLibrary(.{
        .name = "c",
        .root_module = renux_mod,
        .linkage = .static,
    });
    b.installArtifact(libc_a);
}
