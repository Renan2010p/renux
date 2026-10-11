// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// /sbin/login: prompt for a user and start a shell.
//
// The Zig counterpart of the BSD login(1), reduced to the console: read a user
// name, read a password (not echoed, not yet checked since there is no
// authentication database), and exec the user's shell. A real login would
// consult /etc/passwd, verify the password and set up the environment.

const libc: type = @import("libc");

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

/// Read one line, echoing it when `echo` is set.
fn readLine(buf: []u8, echo: bool) usize {
    var len: usize = 0;
    while (true) {
        const c: u8 = libc.stdio.getchar();
        if (c == '\r' or c == '\n') {
            if (echo) {
                libc.stdio.putchar('\n');
            }
            return len;
        }
        if (c == 0x7f or c == 0x08) {
            if (len > 0) {
                len -= 1;
                if (echo) {
                    libc.stdio.printf("\x08 \x08", .{});
                }
            }
            continue;
        }
        if (c < 0x20 or c >= 0x7f) {
            continue;
        }
        if (len < buf.len) {
            buf[len] = c;
            len += 1;
            if (echo) {
                libc.stdio.putchar(c);
            }
        }
    }
}

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = argc;
    _ = argv;

    var user: [64]u8 = undefined;
    var pass: [64]u8 = undefined;

    libc.stdio.printf("login: ", .{});
    _ = readLine(&user, true);

    libc.stdio.printf("Password: ", .{});
    _ = readLine(&pass, false);
    libc.stdio.putchar('\n');

    libc.stdio.printf("\nWelcome to ZenBSD!\n", .{});

    var av: [2]?[*:0]const u8 = .{ "/bin/sh", null };
    _ = libc.syscall.execve("/bin/sh", @ptrCast(&av), envp);

    libc.stdio.puts("login: cannot exec /bin/sh");
    return 1;
}
