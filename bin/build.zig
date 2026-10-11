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
    mod.addImport("csu", libc.module("csu"));

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

    const echo: *Builder.Step.Compile = program(b, target, optimize, libc, "echo", "echo/main.zig");
    const install_echo: *Builder.Step.InstallArtifact = b.addInstallArtifact(echo, .{});
    b.getInstallStep().dependOn(&install_echo.step);

    const pwd: *Builder.Step.Compile = program(b, target, optimize, libc, "pwd", "pwd/main.zig");
    const install_pwd: *Builder.Step.InstallArtifact = b.addInstallArtifact(pwd, .{});
    b.getInstallStep().dependOn(&install_pwd.step);

    const mkdir: *Builder.Step.Compile = program(b, target, optimize, libc, "mkdir", "mkdir/main.zig");
    const install_mkdir: *Builder.Step.InstallArtifact = b.addInstallArtifact(mkdir, .{});
    b.getInstallStep().dependOn(&install_mkdir.step);

    const rm: *Builder.Step.Compile = program(b, target, optimize, libc, "rm", "rm/main.zig");
    const install_rm: *Builder.Step.InstallArtifact = b.addInstallArtifact(rm, .{});
    b.getInstallStep().dependOn(&install_rm.step);

    const rmdir: *Builder.Step.Compile = program(b, target, optimize, libc, "rmdir", "rmdir/main.zig");
    const install_rmdir: *Builder.Step.InstallArtifact = b.addInstallArtifact(rmdir, .{});
    b.getInstallStep().dependOn(&install_rmdir.step);

    // A C program: compiled by clang (through Zig) against the headers in
    // lib/include and linked against the Zig C library.
    const hello_mod: *Builder.Module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("hello/main.zig"),
        .code_model = .default,
    });
    hello_mod.addImport("libc", libc.module("libc"));
    hello_mod.addImport("csu", libc.module("csu"));
    hello_mod.addIncludePath(libc.path("include"));
    hello_mod.addCSourceFile(.{ .file = b.path("hello/main.c"), .flags = &.{} });

    const hello: *Builder.Step.Compile = b.addExecutable(.{
        .name = "hello",
        .root_module = hello_mod,
        .use_lld = true,
        .use_llvm = true,
    });
    hello.setLinkerScript(libc.path("libc/libc.ldscript"));
    const install_hello: *Builder.Step.InstallArtifact = b.addInstallArtifact(hello, .{});
    b.getInstallStep().dependOn(&install_hello.step);

    const wc_mod: *Builder.Module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("wc/main.zig"),
        .code_model = .default,
    });
    wc_mod.addImport("libc", libc.module("libc"));
    wc_mod.addImport("csu", libc.module("csu"));
    wc_mod.addIncludePath(libc.path("include"));
    wc_mod.addCSourceFile(.{ .file = b.path("wc/main.c"), .flags = &.{} });

    const wc: *Builder.Step.Compile = b.addExecutable(.{
        .name = "wc",
        .root_module = wc_mod,
        .use_lld = true,
        .use_llvm = true,
    });
    wc.setLinkerScript(libc.path("libc/libc.ldscript"));
    const install_wc: *Builder.Step.InstallArtifact = b.addInstallArtifact(wc, .{});
    b.getInstallStep().dependOn(&install_wc.step);
}
