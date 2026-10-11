// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// /sbin/init: the first user process.
//
// Following the BSD startup sequence, init runs the system startup script
// /etc/rc and then brings up a login shell. A real init would also start the
// system daemons from /etc/rc.d and spawn getty/login on each terminal; only
// the single-user path exists so far.

const libc: type = @import("libc");

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = argc;
    _ = argv;

    // Attach the console as stdin, stdout and stderr: like the BSD init, open
    // /dev/console and dup2() it onto 0, 1 and 2.
    const cfd: i64 = libc.syscall.open("/dev/tty", 2, 0);
    if (cfd >= 0) {
        _ = libc.syscall.dup2(@intCast(cfd), 0);
        _ = libc.syscall.dup2(@intCast(cfd), 1);
        _ = libc.syscall.dup2(@intCast(cfd), 2);
        if (cfd > 2) {
            _ = libc.syscall.close(@intCast(cfd));
        }
    }

    // Run /etc/rc in a child so init survives it, then wait for it to finish.
    libc.stdio.puts("init: running /etc/rc");
    libc.syslog.msg("init", "startup: running /etc/rc");
    const pid: i32 = libc.syscall.fork();
    if (pid == 0) {
        var rc_argv: [3]?[*:0]const u8 = .{ "/bin/sh", "/etc/rc", null };
        _ = libc.syscall.execve("/bin/sh", @ptrCast(&rc_argv), envp);
        libc.syscall.exit(1);
    }
    _ = libc.syscall.wait(null);
    libc.syslog.msg("init", "multi-user startup complete");

    // Respawn getty on the console, like a real init(8): when the shell it
    // started exits, a new getty (and so a new login) is started.
    while (true) {
        const gpid: i32 = libc.syscall.fork();
        if (gpid == 0) {
            var av: [2]?[*:0]const u8 = .{ "/usr/libexec/getty", null };
            _ = libc.syscall.execve("/usr/libexec/getty", @ptrCast(&av), envp);
            libc.syscall.exit(1);
        }
        _ = libc.syscall.wait(null);
        libc.syslog.msg("init", "getty exited, respawning");
    }
}
