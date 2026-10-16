// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// C library root module.
//
// The Zig counterpart of NetBSD/FreeBSD lib/libc: the library a userland
// program links against. It grows subsystem by subsystem (stdio, string, gen,
// sys, ...); only what the first programs need exists today. Userland modules
// import it by name ("libc"), the same way the kernel imports "limine".

pub const syscall: type = @import("sys/syscall.zig");
pub const stdio: type = @import("stdio/stdio.zig");
pub const syslog: type = @import("gen/syslog.zig");
pub const time: type = @import("gen/time.zig");
pub const dirent: type = @import("gen/dirent.zig");
pub const errno: type = @import("gen/errno.zig");
pub const file: type = @import("stdio/file.zig");
pub const curses: type = @import("curses/curses.zig");
pub const termios: type = @import("gen/termios.zig");
pub const c: type = @import("c.zig");
