// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// /sbin/login: prompt for a user and start a shell.
//
// The Zig counterpart of the BSD login(1), reduced to the console: read a user
// name, read a password with the terminal echo turned off (not checked, since
// there is no authentication database yet), and exec the user's shell. The
// terminal (dev/tty) does the echoing and line editing in canonical mode.

const libc: type = @import("libc");

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

/// Read one line from the terminal (the tty echoes it).
fn readLine(buf: []u8) usize {
    var len: usize = 0;
    while (true) {
        const c: u8 = libc.stdio.getchar();
        if (c == '\r' or c == '\n') {
            return len;
        }
        if (c == 0x7f or c == 0x08) {
            if (len > 0) {
                len -= 1;
            }
            continue;
        }
        if (c < 0x20 or c >= 0x7f) {
            continue;
        }
        if (len < buf.len) {
            buf[len] = c;
            len += 1;
        }
    }
}

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = argc;
    _ = argv;

    var user: [64]u8 = undefined;
    var pass: [64]u8 = undefined;

    libc.stdio.printf("login: ", .{});
    const ulen: usize = readLine(&user);

    // Determine the user id: root, or an ordinary user. Record it so the shell
    // can pick the right prompt.
    var is_root: bool = (ulen == 4);
    if (is_root) {
        const want: [4]u8 = .{ 'r', 'o', 'o', 't' };
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            if (user[i] != want[i]) {
                is_root = false;
            }
        }
    }
    _ = libc.syscall.setuid(if (is_root) 0 else 1000);

    // Read the password with echo disabled, then restore the old attributes.
    var old: libc.syscall.Termios = undefined;
    var changed: bool = false;
    if (libc.syscall.ioctl(0, libc.syscall.TIOCGETA, @intFromPtr(&old)) == 0) {
        var noecho: libc.syscall.Termios = old;
        noecho.c_lflag &= ~libc.syscall.ECHO;
        _ = libc.syscall.ioctl(0, libc.syscall.TIOCSETA, @intFromPtr(&noecho));
        changed = true;
    }
    libc.stdio.printf("Password: ", .{});
    _ = readLine(&pass);
    libc.stdio.putchar('\n');
    if (changed) {
        _ = libc.syscall.ioctl(0, libc.syscall.TIOCSETA, @intFromPtr(&old));
    }

    libc.stdio.printf("\nWelcome to Renux!\n", .{});

    // Record the session in the system log.
    var logbuf: [96]u8 = undefined;
    var ln: usize = 0;
    const prefix: []const u8 = "session opened for user ";
    for (prefix) |c| {
        logbuf[ln] = c;
        ln += 1;
    }
    var ui: usize = 0;
    while (ui < ulen and ln < logbuf.len) : (ui += 1) {
        logbuf[ln] = user[ui];
        ln += 1;
    }
    libc.syslog.msg("login", logbuf[0..ln]);

    var av: [2]?[*:0]const u8 = .{ "/bin/sh", null };
    _ = libc.syscall.execve("/bin/sh", @ptrCast(&av), envp);

    libc.stdio.puts("login: cannot exec /bin/sh");
    return 1;
}
