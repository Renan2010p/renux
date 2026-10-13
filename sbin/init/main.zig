// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// /sbin/init: the first user process.
//
// Following the BSD startup sequence: in a single-user boot (the kernel passes
// -s) init first offers a shell on the console; then it runs the system
// startup script /etc/rc and keeps a getty running on the console.

const libc: type = @import("libc");

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

/// Run `path` (a shell) in a child and wait for it.
fn runShell(path: [*:0]const u8, envp: [*]?[*:0]const u8) void {
    const pid: i32 = libc.syscall.fork();
    if (pid == 0) {
        var av: [2]?[*:0]const u8 = .{ path, null };
        _ = libc.syscall.execve(path, @ptrCast(&av), envp);
        libc.stdio.puts("init: cannot exec the shell");
        libc.syscall.exit(1);
    }
    _ = libc.syscall.wait(null);
}

/// Single-user mode, as FreeBSD's init does it: offer a shell on the console
/// and, when it exits, continue to multi-user operation.
fn singleUser(envp: [*]?[*:0]const u8) void {
    libc.syslog.msg("init", "single user mode");
    libc.stdio.printf("Enter full pathname of shell or RETURN for /bin/sh: ", .{});
    var buf: [128:0]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        var c: [1]u8 = undefined;
        if (libc.syscall.read(0, &c) != 1 or c[0] == '\n' or c[0] == '\r') break;
        buf[n] = c[0];
        n += 1;
    }
    buf[n] = 0;
    const shell: [*:0]const u8 = if (n == 0) "/bin/sh" else &buf;
    runShell(shell, envp);
}

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    // The kernel passes -s for a single-user boot.
    var single: bool = false;
    var a: usize = 1;
    while (a < @as(usize, @intCast(argc))) : (a += 1) {
        const arg = argv[a] orelse continue;
        if (arg[0] == '-' and arg[1] == 's') single = true;
    }

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

    if (single) {
        singleUser(envp);
    }

    // Run /etc/rc in a child so init survives it, then wait for it to finish.
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
