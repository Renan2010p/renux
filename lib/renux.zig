// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// Static C library root.
//
// This root pulls in the C ABI wrappers and the C startup, so the standalone
// libc.a contains both: a C program links against it with the userland linker
// script and gets _start plus the whole library, without Zig's module system.

pub const libc: type = @import("libc");
pub const csu: type = @import("csu");

comptime {
    _ = libc.c;
    _ = csu.crt0;
}
