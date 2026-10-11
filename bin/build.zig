// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// /bin build definition.
//
// Builds the user-visible programs (currently the shell). Each is a static,
// non-PIE ELF at a fixed low address, linking the C library.

const std: type = @import("std");
const builtin: type = std.builtin;
const Target: type = std.Target;
const Query: type = Target.Query;
const Builder: type = std.Build;

/// Build one program against the C library.
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
    exe.setLinkerScript(libc.path("libc/libc.ldscript"));
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

    // The C library module inherits this compilation's target and optimize
    // mode, so no options need to be passed.
    const libc: *Builder.Dependency = b.dependency("libc", .{});

    const sh: *Builder.Step.Compile = program(b, target, optimize, libc, "sh", "sh/main.zig");
    const install_sh: *Builder.Step.InstallArtifact = b.addInstallArtifact(sh, .{});
    b.getInstallStep().dependOn(&install_sh.step);

    const ls: *Builder.Step.Compile = program(b, target, optimize, libc, "ls", "ls/main.zig");
    const install_ls: *Builder.Step.InstallArtifact = b.addInstallArtifact(ls, .{});
    b.getInstallStep().dependOn(&install_ls.step);

    const cat: *Builder.Step.Compile = program(b, target, optimize, libc, "cat", "cat/main.zig");
    const install_cat: *Builder.Step.InstallArtifact = b.addInstallArtifact(cat, .{});
    b.getInstallStep().dependOn(&install_cat.step);

    const stat: *Builder.Step.Compile = program(b, target, optimize, libc, "stat", "stat/main.zig");
    const install_stat: *Builder.Step.InstallArtifact = b.addInstallArtifact(stat, .{});
    b.getInstallStep().dependOn(&install_stat.step);
}
