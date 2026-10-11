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

    const init_mod: *Builder.Module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("init/main.zig"),
        .code_model = .default,
    });

    // The C library lives in ../lib, a separate package; depend on it and add
    // its "libc" module as an import.
    const libc_dep: *Builder.Dependency = b.dependency("libc", .{
        .target = target,
        .optimize = optimize,
    });
    init_mod.addImport("libc", libc_dep.module("libc"));

    const init_exec: *Builder.Step.Compile = b.addExecutable(.{
        .name = "init",
        .root_module = init_mod,
        .use_lld = true,
        .use_llvm = true,
    });

    // Static, non-PIE image at a fixed low address, so the kernel's ELF loader
    // can map it directly from the program headers.
    init_exec.setLinkerScript(b.path("user.ldscript"));

    const install_init: *Builder.Step.InstallArtifact = b.addInstallArtifact(init_exec, .{});

    b.getInstallStep().dependOn(&install_init.step);
}
