// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// /sbin/init: the first user process.
//
// It talks to the kernel only through the C library (libc), which is where the
// system call wrappers live. This file stays machine independent.

const libc: type = @import("libc");

export fn _start() callconv(.c) noreturn {
    libc.stdio.printf("hello from userland (pid %d)\n", .{1});
    libc.stdio.printf("libc formatting: %s, %d, %u, %x, %c\n", .{ "str", -42, 42, 255, '!' });
    libc.stdio.puts("init: exiting");
    libc.syscall.exit(0);
}
