// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// /sbin build definition.
//
// Builds the system programs (currently init). Each is a static, non-PIE ELF at
// a fixed low address, linking the C library.

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

    const init: *Builder.Step.Compile = program(b, target, optimize, libc, "init", "init/main.zig");
    const install_init: *Builder.Step.InstallArtifact = b.addInstallArtifact(init, .{});

    b.getInstallStep().dependOn(&install_init.step);
}
