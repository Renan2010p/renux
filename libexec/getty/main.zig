// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// /sbin/getty: open a terminal and run login.
//
// The Zig counterpart of the BSD getty(8), reduced to the console: attach
// /dev/console to standard input, output and error, print the login banner,
// and hand over to login(8).

const libc: type = @import("libc");

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = argc;
    _ = argv;

    // Attach /dev/console as stdin, stdout and stderr.
    const cfd: i64 = libc.syscall.open("/dev/tty", 2, 0);
    if (cfd >= 0) {
        _ = libc.syscall.dup2(@intCast(cfd), 0);
        _ = libc.syscall.dup2(@intCast(cfd), 1);
        _ = libc.syscall.dup2(@intCast(cfd), 2);
        if (cfd > 2) {
            _ = libc.syscall.close(@intCast(cfd));
        }
    }

    libc.stdio.printf("\nRenux (amd64) console\n\n", .{});

    // FreeBSD-style banner: the date/time, then the terminal name.
    var tv: libc.syscall.Timeval = .{ .tv_sec = 0, .tv_usec = 0 };
    _ = libc.syscall.gettimeofdayRaw(&tv);
    if (libc.time.ctime(&tv.tv_sec)) |p| {
        var i: usize = 0;
        while (p[i] != 0) : (i += 1) {}
        _ = libc.syscall.write(1, p[0..i]);
    }
    libc.stdio.puts("Renux/amd64 (renux) (ttyv0)");
    libc.stdio.putchar('\n');

    libc.syslog.msg("getty", "started on /dev/tty");

    var av: [2]?[*:0]const u8 = .{ "/usr/bin/login", null };
    _ = libc.syscall.execve("/usr/bin/login", @ptrCast(&av), envp);

    libc.stdio.puts("getty: cannot exec /sbin/login");
    return 1;
}
