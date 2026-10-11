// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// /sbin/init: the first user process.
//
// Following the BSD startup sequence, init runs the system startup script
// /etc/rc and then brings up a login shell. A real init would also start the
// system daemons from /etc/rc.d and spawn getty/login on each terminal; only
// the single-user path exists so far.

const libc: type = @import("libc");

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = argc;
    _ = argv;

    // Run /etc/rc in a child so init survives it, then wait for it to finish.
    libc.stdio.puts("init: running /etc/rc");
    const pid: i32 = libc.syscall.fork();
    if (pid == 0) {
        var rc_argv: [3]?[*:0]const u8 = .{ "/bin/sh", "/etc/rc", null };
        _ = libc.syscall.execve("/bin/sh", @ptrCast(&rc_argv), envp);
        libc.syscall.exit(1);
    }
    _ = libc.syscall.wait(null);

    // Start the login shell. This replaces init for now.
    libc.stdio.puts("init: starting /bin/sh");
    var sh_argv: [2]?[*:0]const u8 = .{ "/bin/sh", null };
    _ = libc.syscall.execve("/bin/sh", @ptrCast(&sh_argv), envp);

    libc.stdio.puts("init: cannot exec /bin/sh");
    return 1;
}
