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

    b.installArtifact(kern_exec);
}
