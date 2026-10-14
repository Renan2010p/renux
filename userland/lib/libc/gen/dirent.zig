// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Directory reading.
//
// The Zig counterpart of NetBSD's lib/libc/gen/opendir.c and readdir.c, reduced
// to the calls a program uses: opendir() opens a directory and readdir() parses
// the records getdents(2) fills in, one at a time, into a per-DIR entry.

const syscall: type = @import("../sys/syscall.zig");
const heap: type = @import("../stdlib/malloc.zig");

/// The `struct dirent` a caller sees; the kernel's own record is parsed into
/// this.
pub const Dirent: type = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_namlen: u16,
    d_name: [256]u8,
};

/// An open directory stream (`DIR *` in C).
const DIR: type = struct {
    fd: c_int,
    len: usize,
    pos: usize,
    buf: [1024]u8,
    entry: Dirent,
};

pub export fn opendir(path: [*:0]const u8) ?*DIR {
    const fd: i64 = syscall.open(path, syscall.O_RDONLY | syscall.O_DIRECTORY, 0);
    if (fd < 0) {
        return null;
    }
    const raw: ?*anyopaque = heap.malloc(@sizeOf(DIR)) orelse {
        _ = syscall.close(@intCast(fd));
        return null;
    };
    const d: *DIR = @ptrCast(@alignCast(raw));
    d.fd = @intCast(fd);
    d.len = 0;
    d.pos = 0;
    return d;
}

pub export fn closedir(d: *DIR) c_int {
    _ = syscall.close(@intCast(d.fd));
    heap.free(@ptrCast(d));
    return 0;
}

fn readU16(p: [*]const u8, off: usize) u16 {
    return @as(u16, p[off]) | (@as(u16, p[off + 1]) << 8);
}

fn readU64(p: [*]const u8, off: usize) u64 {
    var v: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        v |= @as(u64, p[off + i]) << @intCast(i * 8);
    }
    return v;
}

pub export fn readdir(d: *DIR) ?*Dirent {
    while (true) {
        if (d.pos + 24 <= d.len) {
            const p: [*]const u8 = @ptrCast(&d.buf[d.pos]);
            const reclen: u16 = readU16(p, 16);
            if (reclen == 0) {
                return null;
            }
            const namlen: u16 = readU16(p, 20);
            d.entry.d_ino = readU64(p, 0);
            d.entry.d_off = @bitCast(readU64(p, 8));
            d.entry.d_reclen = reclen;
            d.entry.d_type = p[18];
            d.entry.d_namlen = namlen;
            var i: usize = 0;
            while (i < namlen and i < 255) : (i += 1) {
                d.entry.d_name[i] = p[24 + i];
            }
            d.entry.d_name[i] = 0;
            d.pos += reclen;
            return &d.entry;
        }

        const r: i64 = @bitCast(syscall.getdents(@intCast(d.fd), d.buf[0..]));
        if (r <= 0) {
            return null;
        }
        d.len = @intCast(r);
        d.pos = 0;
    }
}
