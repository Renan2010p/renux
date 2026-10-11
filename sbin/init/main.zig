// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// /sbin/init: the first user process.
//
// Once process creation works, init's job is to start the system: for now it
// execs the shell; a real init would run /etc/rc and spawn getty/login.

const libc: type = @import("libc");

export fn _start() callconv(.c) noreturn {
    libc.stdio.puts("init: starting /bin/sh");

    _ = libc.syscall.execve("/bin/sh");

    libc.stdio.puts("init: cannot exec /bin/sh");
    libc.syscall.exit(1);
}
