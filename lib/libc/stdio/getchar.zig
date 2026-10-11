// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// getchar.
//
// The Zig counterpart of NetBSD/FreeBSD lib/libc/stdio/getchar.c: read one
// character from standard input (file descriptor 0).

const syscall: type = @import("../sys/syscall.zig");

/// Read one character from standard input, blocking until one is available.
pub fn getchar() u8 {
    var c: [1]u8 = undefined;
    _ = syscall.read(0, &c);
    return c[0];
}
