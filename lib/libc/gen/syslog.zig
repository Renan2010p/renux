// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// System logging.
//
// The Zig counterpart of NetBSD's lib/libc/gen/syslog.c, reduced to appending
// lines to /var/log/messages. There is no syslogd yet; the message is written
// straight to the file.

const syscall: type = @import("../sys/syscall.zig");
const cprintf: type = @import("../stdio/cprintf.zig");
const VaList: type = @import("std").builtin.VaList;

const LOG_PATH: [*:0]const u8 = "/var/log/messages";

var ident: [*:0]const u8 = "renux";

pub export fn openlog(id: [*:0]const u8, option: c_int, facility: c_int) void {
    _ = option;
    _ = facility;
    ident = id;
}

pub export fn closelog() void {}

fn cstr(s: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {}
    return s[0..n];
}

fn appendUint(buf: []u8, n: *usize, value: u64) void {
    var tmp: [20]u8 = undefined;
    var k: usize = 0;
    var v: u64 = value;
    if (v == 0) {
        tmp[0] = '0';
        k = 1;
    }
    while (v != 0) {
        tmp[k] = @intCast('0' + (v % 10));
        k += 1;
        v /= 10;
    }
    var j: usize = k;
    while (j > 0) {
        j -= 1;
        if (n.* < buf.len) {
            buf[n.*] = tmp[j];
            n.* += 1;
        }
    }
}

fn appendSlice(buf: []u8, n: *usize, s: []const u8) void {
    for (s) |c| {
        if (n.* < buf.len) {
            buf[n.*] = c;
            n.* += 1;
        }
    }
}

/// Append one line to /var/log/messages: "[<sec>] <ident>: <message>\n".
fn writeLine(id: []const u8, message: []const u8) void {
    var line: [640]u8 = undefined;
    var n: usize = 0;

    var tv: syscall.Timeval = .{ .tv_sec = 0, .tv_usec = 0 };
    _ = syscall.gettimeofdayRaw(&tv);

    appendSlice(&line, &n, "[");
    appendUint(&line, &n, @intCast(tv.tv_sec));
    appendSlice(&line, &n, "] ");
    appendSlice(&line, &n, id);
    appendSlice(&line, &n, ": ");
    appendSlice(&line, &n, message);
    appendSlice(&line, &n, "\n");

    const fd: i64 = syscall.open(LOG_PATH, syscall.O_WRONLY | syscall.O_CREAT, 0o644);
    if (fd < 0) {
        return;
    }
    _ = syscall.lseek(@intCast(fd), 0, 2); // SEEK_END
    _ = syscall.write(@intCast(fd), line[0..n]);
    _ = syscall.close(@intCast(fd));
}

/// Log `text` under `id` (a Zig-friendly entry for the system programs).
pub fn msg(id: [*:0]const u8, text: []const u8) void {
    writeLine(cstr(id), text);
}

/// syslogMsg: log a plain message under `id`.
pub export fn syslogMsg(pri: c_int, id: [*:0]const u8, message: [*:0]const u8) void {
    _ = pri;
    writeLine(cstr(id), cstr(message));
}

/// syslog(3): format the message and log it under the current ident.
pub export fn syslog(pri: c_int, fmt: [*:0]const u8, ...) callconv(.c) void {
    _ = pri;
    var ap = @cVaStart();
    var mbuf: [512]u8 = undefined;
    _ = cprintf.vsnprintf(&mbuf, mbuf.len, fmt, &ap);
    @cVaEnd(&ap);
    var m: usize = 0;
    while (m < mbuf.len and mbuf[m] != 0) : (m += 1) {}
    writeLine(cstr(ident), mbuf[0..m]);
}
