// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project

const std: type = @import("std");
const builtin: type = std.builtin;
const Target: type = std.Target;
const Query: type = Target.Query;
const Builder: type = std.Build;

/// Build one userland program: a static, non-PIE ELF at a fixed low address,
/// linking the C library.
fn program(
    b: *Builder,
    target: Builder.ResolvedTarget,
    optimize: builtin.OptimizeMode,
    libc: *Builder.Dependency,
    name: []const u8,
    source: []const u8,
) *Builder.Step.Compile {
    const mod: *Builder.Module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path(source),
        .code_model = .default,
    });
    mod.addImport("libc", libc.module("libc"));

    const exe: *Builder.Step.Compile = b.addExecutable(.{
        .name = name,
        .root_module = mod,
        .use_lld = true,
        .use_llvm = true,
    });
    exe.setLinkerScript(b.path("user.ldscript"));
    return exe;
}

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

    // The C library lives in ../lib, a separate package; depend on it and add
    // its "libc" module as an import.
    const libc: *Builder.Dependency = b.dependency("libc", .{
        .target = target,
        .optimize = optimize,
    });

    const init: *Builder.Step.Compile = program(b, target, optimize, libc, "init", "init/main.zig");
    const sh: *Builder.Step.Compile = program(b, target, optimize, libc, "sh", "sh/main.zig");

    const install_init: *Builder.Step.InstallArtifact = b.addInstallArtifact(init, .{});
    const install_sh: *Builder.Step.InstallArtifact = b.addInstallArtifact(sh, .{});

    b.getInstallStep().dependOn(&install_init.step);
    b.getInstallStep().dependOn(&install_sh.step);
}
