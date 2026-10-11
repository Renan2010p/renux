// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Formatted output.
//
// The Zig counterpart of the formatted-output core of NetBSD's lib/libc/stdio,
// reduced to the conversions the C programs built so far use. A single
// formatter writes through a sink (a descriptor or a string), and supports the
// '-' flag and a field width; the C variable arguments are read with @cVaArg.

const syscall: type = @import("../sys/syscall.zig");
const file: type = @import("file.zig");
const VaList: type = @import("std").builtin.VaList;

var sink_fd: c_int = 1;
var sink_buf: ?[*]u8 = null;
var sink_pos: usize = 0;
var out_buf: [256]u8 = undefined;
var out_len: usize = 0;

fn flush() void {
    if (out_len == 0) {
        return;
    }
    _ = syscall.write(@intCast(sink_fd), out_buf[0..out_len]);
    out_len = 0;
}

fn out(c: u8) void {
    if (sink_buf) |b| {
        b[sink_pos] = c;
        sink_pos += 1;
        return;
    }
    if (out_len == out_buf.len) {
        flush();
    }
    out_buf[out_len] = c;
    out_len += 1;
}

fn padTo(width: usize, len: usize) void {
    var k: usize = len;
    while (k < width) : (k += 1) {
        out(' ');
    }
}

fn emitStr(s: [*:0]const u8, width: usize, left: bool) void {
    var len: usize = 0;
    while (s[len] != 0) : (len += 1) {}
    if (!left) {
        padTo(width, len);
    }
    var i: usize = 0;
    while (i < len) : (i += 1) {
        out(s[i]);
    }
    if (left) {
        padTo(width, len);
    }
}

fn digit(d: u64, upper: bool) u8 {
    if (d < 10) {
        return @as(u8, '0') + @as(u8, @intCast(d));
    }
    const base: u8 = if (upper) 'A' else 'a';
    return base + @as(u8, @intCast(d - 10));
}

fn emitNum(value: u64, base: u64, upper: bool, neg: bool, width: usize, left: bool) void {
    var buf: [32]u8 = undefined;
    var i: usize = buf.len;
    var x: u64 = value;
    if (x == 0) {
        i -= 1;
        buf[i] = '0';
    }
    while (x != 0) {
        i -= 1;
        buf[i] = digit(x % base, upper);
        x /= base;
    }
    const digits: []const u8 = buf[i..];
    const len: usize = digits.len + @intFromBool(neg);

    if (!left) {
        padTo(width, len);
    }
    if (neg) {
        out('-');
    }
    for (digits) |c| {
        out(c);
    }
    if (left) {
        padTo(width, len);
    }
}

fn formatLoop(fmt: [*:0]const u8, ap: *VaList) void {
    var i: usize = 0;
    while (fmt[i] != 0) {
        if (fmt[i] != '%') {
            out(fmt[i]);
            i += 1;
            continue;
        }
        i += 1;

        // Flags (only '-' is applied) and field width.
        var left: bool = false;
        while (true) {
            if (fmt[i] == '-') {
                left = true;
                i += 1;
            } else if (fmt[i] == '0' or fmt[i] == '+' or fmt[i] == ' ' or fmt[i] == '#') {
                i += 1;
            } else {
                break;
            }
        }
        var width: usize = 0;
        while (fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
            width = width * 10 + (fmt[i] - '0');
        }
        if (fmt[i] == '.') {
            i += 1;
            while (fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {}
        }
        var is_long: bool = false;
        while (fmt[i] == 'l') : (i += 1) {
            is_long = true;
        }

        switch (fmt[i]) {
            'd', 'i' => {
                if (is_long) {
                    const v: i64 = @cVaArg(ap, c_long);
                    emitNum(@intCast(if (v < 0) -v else v), 10, false, v < 0, width, left);
                } else {
                    const v: c_int = @cVaArg(ap, c_int);
                    emitNum(@intCast(if (v < 0) -v else v), 10, false, v < 0, width, left);
                }
            },
            'u' => {
                if (is_long) {
                    emitNum(@cVaArg(ap, c_ulong), 10, false, false, width, left);
                } else {
                    emitNum(@cVaArg(ap, c_uint), 10, false, false, width, left);
                }
            },
            'x' => {
                if (is_long) {
                    emitNum(@cVaArg(ap, c_ulong), 16, false, false, width, left);
                } else {
                    emitNum(@cVaArg(ap, c_uint), 16, false, false, width, left);
                }
            },
            'X' => {
                if (is_long) {
                    emitNum(@cVaArg(ap, c_ulong), 16, true, false, width, left);
                } else {
                    emitNum(@cVaArg(ap, c_uint), 16, true, false, width, left);
                }
            },
            'p' => {
                out('0');
                out('x');
                emitNum(@cVaArg(ap, usize), 16, false, false, 0, false);
            },
            's' => emitStr(@cVaArg(ap, [*:0]const u8), width, left),
            'c' => out(@intCast(@cVaArg(ap, c_int) & 0xff)),
            '%' => out('%'),
            else => {
                out('%');
                out(fmt[i]);
            },
        }
        i += 1;
    }
}

pub export fn printf(fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    sink_fd = 1;
    formatLoop(fmt, &ap);
    flush();
    @cVaEnd(&ap);
    return 0;
}

pub export fn fprintf(f: *file.File, fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    sink_fd = f.fd;
    formatLoop(fmt, &ap);
    flush();
    @cVaEnd(&ap);
    return 0;
}

pub export fn sprintf(buf: [*]u8, fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    sink_buf = buf;
    sink_pos = 0;
    formatLoop(fmt, &ap);
    buf[sink_pos] = 0;
    const n: usize = sink_pos;
    sink_buf = null;
    @cVaEnd(&ap);
    return @intCast(n);
}
