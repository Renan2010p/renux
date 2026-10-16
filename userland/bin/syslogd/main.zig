// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// /usr/sbin/syslogd: the system log daemon.
//
// The Zig counterpart of FreeBSD's syslogd(8), reduced to what Renux needs
// today: it copies the kernel's messages into the system log. Once a second
// it reads the kernel message buffer (the klog system call), and records each
// line it has not seen yet in /var/log/messages under the tag "kernel".
// Programs write their own messages to the log directly (libc's syslog), so
// there is no socket to listen on.

const libc: type = @import("libc");

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

/// The kernel message buffer is at most this large.
const MSGBUF_SIZE: usize = 16384;
/// Longer lines are split.
const LINE_MAX: usize = 600;

/// How long to sleep between reads. The kernel blocks the process while it
/// sleeps, so waiting costs no CPU time.
const POLL_INTERVAL: libc.syscall.Timespec2 = .{ .tv_sec = 1, .tv_nsec = 0 };

var msgbuf: [MSGBUF_SIZE]u8 = undefined;

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = argc;
    _ = argv;
    _ = envp;
    // How much of the message buffer has been logged already.
    var seen: usize = 0;
    while (true) {
        const len: i64 = libc.syscall.klogRaw(&msgbuf);
        if (len > 0 and @as(usize, @intCast(len)) > seen) {
            seen += logLines(msgbuf[seen..@intCast(len)]);
        }
        _ = libc.syscall.nanosleep(&POLL_INTERVAL, null);
    }
}

/// Log each complete line of `text` (split at LINE_MAX characters), and
/// return how many bytes were consumed. A last line without its newline is
/// left for the next read: the kernel may still be writing it. Blank lines
/// are skipped.
fn logLines(text: []const u8) usize {
    var start: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '\n' or i - start == LINE_MAX) {
            if (i > start) libc.syslog.msg("kernel", text[start..i]);
            start = if (c == '\n') i + 1 else i;
        }
    }
    return start;
}
