// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// C library root module.
//
// The Zig counterpart of NetBSD/FreeBSD lib/libc: the library a userland
// program links against. It grows subsystem by subsystem (stdio, string, gen,
// sys, ...); only what the first programs need exists today. Userland modules
// import it by name ("libc"), the same way the kernel imports "limine".

pub const syscall: type = @import("sys/syscall.zig");
pub const stdio: type = @import("stdio/printf.zig");
