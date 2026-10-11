// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// stdio namespace.
//
// Re-exports the stdio routines so a program can reach them as libc.stdio.*,
// mirroring how <stdio.h> gathers them in one place.

pub const printf = @import("printf.zig").printf;
pub const puts = @import("printf.zig").puts;
pub const putchar = @import("printf.zig").putchar;
pub const getchar = @import("getchar.zig").getchar;
