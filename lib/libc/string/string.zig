// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// C string functions.
//
// The Zig counterpart of NetBSD's lib/libc/string, reduced to the functions the
// C programs built so far use. The C ABI wrappers live in libc/c.zig.

pub fn memcpy(dst: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        dst[i] = src[i];
    }
    return dst;
}

pub fn memset(dst: [*]u8, c: u8, n: usize) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        dst[i] = c;
    }
    return dst;
}

pub fn memmove(dst: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    if (@intFromPtr(dst) < @intFromPtr(src)) {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            dst[i] = src[i];
        }
    } else {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            dst[i] = src[i];
        }
    }
    return dst;
}

pub fn strlen(s: [*:0]const u8) usize {
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {}
    return n;
}

pub fn strcmp(a: [*:0]const u8, b: [*:0]const u8) c_int {
    var i: usize = 0;
    while (a[i] != 0 and a[i] == b[i]) : (i += 1) {}
    return @as(c_int, a[i]) - @as(c_int, b[i]);
}

pub fn strncmp(a: [*:0]const u8, b: [*:0]const u8, n: usize) c_int {
    var i: usize = 0;
    while (i < n and a[i] != 0 and a[i] == b[i]) : (i += 1) {}
    if (i == n) {
        return 0;
    }
    return @as(c_int, a[i]) - @as(c_int, b[i]);
}

pub fn strcpy(dst: [*:0]u8, src: [*:0]const u8) [*:0]u8 {
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) {
        dst[i] = src[i];
    }
    dst[i] = 0;
    return dst;
}

pub fn strncpy(dst: [*:0]u8, src: [*:0]const u8, n: usize) [*:0]u8 {
    var i: usize = 0;
    while (i < n and src[i] != 0) : (i += 1) {
        dst[i] = src[i];
    }
    while (i < n) : (i += 1) {
        dst[i] = 0;
    }
    return dst;
}

pub fn strchr(s: [*:0]const u8, c: u8) ?[*:0]u8 {
    var i: usize = 0;
    while (true) : (i += 1) {
        if (s[i] == c) {
            return @ptrCast(@constCast(&s[i]));
        }
        if (s[i] == 0) {
            return null;
        }
    }
}
