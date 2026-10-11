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
    _ = b.addModule("libc", .{
        .root_source_file = b.path("libc/libc.zig"),
    });
}
