// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// C library build definition.
//
// Exposes the library as a module named "libc" that userland programs import by
// name. Consumers (sbin/) depend on this package via their build.zig.zon.
//
//   zig build            (from lib/) is a no-op that validates the package
//   zig build test       (reserved for the library's tests)

const std: type = @import("std");
const Builder: type = std.Build;

pub fn build(b: *Builder) !void {
    const target: Builder.ResolvedTarget = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode = b.standardOptimizeOption(.{});

    // The C library, importable as "libc".
    _ = b.addModule("libc", .{
        .root_source_file = b.path("libc/libc.zig"),
        .target = target,
        .optimize = optimize,
    });
}
