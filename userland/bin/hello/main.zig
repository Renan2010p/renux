// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// C program module root.
//
// This module has no Zig code of its own: it pulls in the C startup (_start)
// and the C ABI wrappers of the C library, so their exported symbols are
// emitted and link against main() defined in main.c.

comptime {
    _ = @import("csu").crt0;
    _ = @import("libc").c;
}
