// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// C library build definition.
//
// Exposes the library as a module named "libc" that userland programs import by
// name. The target and optimize mode are inherited from the importing
// compilation, so the library always matches the program that links it (in
// particular, it is built for the same CPU baseline, never the host CPU).
//
// Consumers (sbin/) depend on this package via their build.zig.zon.

const std: type = @import("std");
const Builder: type = std.Build;

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
}
