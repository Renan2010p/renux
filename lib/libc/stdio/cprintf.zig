// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
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
var sink_limit: usize = 0;
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
        if (sink_limit == 0 or sink_pos + 1 < sink_limit) {
            b[sink_pos] = c;
        }
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
    sink_limit = 0;
    formatLoop(fmt, &ap);
    buf[sink_pos] = 0;
    const n: usize = sink_pos;
    sink_buf = null;
    @cVaEnd(&ap);
    return @intCast(n);
}

pub export fn snprintf(buf: [*]u8, size: usize, fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    const n: c_int = vsnprintf(buf, size, fmt, &ap);
    @cVaEnd(&ap);
    return n;
}

/// Format `fmt` with the argument list `ap` into `buf` (NUL-terminated, at
/// most `size` bytes). Zig-callable by the logging code.
pub fn vsnprintf(buf: [*]u8, size: usize, fmt: [*:0]const u8, ap: *VaList) c_int {
    sink_buf = buf;
    sink_pos = 0;
    sink_limit = size;
    formatLoop(fmt, ap);
    if (size > 0) {
        const at: usize = if (sink_pos < size) sink_pos else size - 1;
        buf[at] = 0;
    }
    const n: usize = sink_pos;
    sink_buf = null;
    sink_limit = 0;
    return @intCast(n);
}

/// Read conversions from a string (a small sscanf: %d, %u, %x, %s, %c).
pub export fn sscanf(str: [*:0]const u8, fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    var si: usize = 0;
    var fi: usize = 0;
    var count: c_int = 0;

    while (fmt[fi] != 0) {
        const fch: u8 = fmt[fi];
        if (fch == ' ' or fch == '\t') {
            fi += 1;
            continue;
        }
        if (fch != '%') {
            if (str[si] != fch) {
                break;
            }
            si += 1;
            fi += 1;
            continue;
        }

        fi += 1;
        var is_long: bool = false;
        while (fmt[fi] == 'l') : (fi += 1) {
            is_long = true;
        }
        switch (fmt[fi]) {
            'd', 'i' => {
                while (str[si] == ' ') : (si += 1) {}
                var neg: bool = false;
                if (str[si] == '-') {
                    neg = true;
                    si += 1;
                } else if (str[si] == '+') {
                    si += 1;
                }
                var v: i64 = 0;
                while (str[si] >= '0' and str[si] <= '9') : (si += 1) {
                    v = v * 10 + (str[si] - '0');
                }
                if (neg) {
                    v = -v;
                }
                if (is_long) {
                    @cVaArg(&ap, *i64).* = v;
                } else {
                    @cVaArg(&ap, *c_int).* = @intCast(v);
                }
                count += 1;
            },
            'u', 'x' => {
                while (str[si] == ' ') : (si += 1) {}
                const base: u64 = if (fmt[fi] == 'x') 16 else 10;
                var v: u64 = 0;
                while (true) {
                    const d: u8 = str[si];
                    const val: u8 = if (d >= '0' and d <= '9') d - '0' else if (d >= 'a' and d <= 'f') d - 'a' + 10 else if (d >= 'A' and d <= 'F') d - 'A' + 10 else 255;
                    if (val == 255 or val >= base) {
                        break;
                    }
                    v = v * base + val;
                    si += 1;
                }
                if (is_long) {
                    @cVaArg(&ap, *u64).* = v;
                } else {
                    @cVaArg(&ap, *c_uint).* = @intCast(v);
                }
                count += 1;
            },
            's' => {
                while (str[si] == ' ') : (si += 1) {}
                const p: [*]u8 = @cVaArg(&ap, [*]u8);
                var k: usize = 0;
                while (str[si] != 0 and str[si] != ' ' and str[si] != '\t') : (si += 1) {
                    p[k] = str[si];
                    k += 1;
                }
                p[k] = 0;
                count += 1;
            },
            'c' => {
                const p: [*]u8 = @cVaArg(&ap, [*]u8);
                p[0] = str[si];
                if (str[si] != 0) {
                    si += 1;
                }
                count += 1;
            },
            else => {},
        }
        if (fmt[fi] != 0) {
            fi += 1;
        }
    }

    @cVaEnd(&ap);
    return count;
}
