// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// A C printf.
//
// The Zig counterpart of the formatted-output core of NetBSD's lib/libc/stdio,
// reduced to the conversions the C programs built so far use. It reads the C
// variable arguments with @cVaArg, so a C caller sees an ordinary printf.

const syscall: type = @import("../sys/syscall.zig");

var out_buf: [256]u8 = undefined;
var out_len: usize = 0;

fn flush() void {
    if (out_len == 0) {
        return;
    }
    _ = syscall.write(1, out_buf[0..out_len]);
    out_len = 0;
}

fn out(c: u8) void {
    if (out_len == out_buf.len) {
        flush();
    }
    out_buf[out_len] = c;
    out_len += 1;
}

fn outStr(s: [*:0]const u8) void {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        out(s[i]);
    }
}

fn digit(d: u64, upper: bool) u8 {
    if (d < 10) {
        return @as(u8, '0') + @as(u8, @intCast(d));
    }
    const base: u8 = if (upper) 'A' else 'a';
    return base + @as(u8, @intCast(d - 10));
}

fn outUnsigned(v: u64, base: u64, upper: bool) void {
    var buf: [32]u8 = undefined;
    var i: usize = buf.len;
    var x: u64 = v;
    if (x == 0) {
        i -= 1;
        buf[i] = '0';
    }
    while (x != 0) {
        i -= 1;
        buf[i] = digit(x % base, upper);
        x /= base;
    }
    while (i < buf.len) : (i += 1) {
        out(buf[i]);
    }
}

fn outSigned(v: i64) void {
    if (v < 0) {
        out('-');
        outUnsigned(@intCast(-v), 10, false);
    } else {
        outUnsigned(@intCast(v), 10, false);
    }
}

pub export fn printf(fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();

    var i: usize = 0;
    while (fmt[i] != 0) : (i += 1) {
        if (fmt[i] != '%') {
            out(fmt[i]);
            continue;
        }
        i += 1;
        var is_long: bool = false;
        while (fmt[i] == 'l') : (i += 1) {
            is_long = true;
        }

        switch (fmt[i]) {
            'd', 'i' => {
                if (is_long) {
                    outSigned(@cVaArg(&ap, c_long));
                } else {
                    outSigned(@cVaArg(&ap, c_int));
                }
            },
            'u' => {
                if (is_long) {
                    outUnsigned(@cVaArg(&ap, c_ulong), 10, false);
                } else {
                    outUnsigned(@cVaArg(&ap, c_uint), 10, false);
                }
            },
            'x' => {
                if (is_long) {
                    outUnsigned(@cVaArg(&ap, c_ulong), 16, false);
                } else {
                    outUnsigned(@cVaArg(&ap, c_uint), 16, false);
                }
            },
            'X' => {
                if (is_long) {
                    outUnsigned(@cVaArg(&ap, c_ulong), 16, true);
                } else {
                    outUnsigned(@cVaArg(&ap, c_uint), 16, true);
                }
            },
            'p' => {
                out('0');
                out('x');
                outUnsigned(@cVaArg(&ap, usize), 16, false);
            },
            's' => {
                outStr(@cVaArg(&ap, [*:0]const u8));
            },
            'c' => {
                out(@intCast(@cVaArg(&ap, c_int) & 0xff));
            },
            '%' => out('%'),
            else => {
                out('%');
                out(fmt[i]);
            },
        }
    }

    @cVaEnd(&ap);
    flush();
    return 0;
}
