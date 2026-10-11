// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Device switch tables.
//
// This is the Zig counterpart of NetBSD's sys/sys/conf.h, reduced to the
// character device switch: a table indexed by device major number, holding a
// vector of routines that a device driver provides. open(2) on a character
// device node dispatches through here.

/// Number of major device numbers.
pub const NCDEV: usize = 16;

/// Character device operations (NetBSD's struct cdevsw, reduced).
pub const Cdevsw: type = struct {
    /// Name, for diagnostics.
    name: []const u8,
    /// Called on open; returns a per-open context (may be null).
    open: *const fn (dev: u64, flags: i32) ?*anyopaque,
    /// Read up to `buf.len` bytes; -EAGAIN when no data is ready.
    read: *const fn (ctx: ?*anyopaque, buf: []u8) isize,
    /// Write `buf`.
    write: *const fn (ctx: ?*anyopaque, buf: []const u8) isize,
    /// Called when the last reference to the open file is dropped.
    close: *const fn (ctx: ?*anyopaque) i32,
};

/// The registered character devices, by major number.
pub var cdevsw: [NCDEV]?*const Cdevsw = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null };

/// Register `sw` as the character device for major number `maj`.
pub fn registerCdev(maj: usize, sw: *const Cdevsw) void {
    if (maj < NCDEV) {
        cdevsw[maj] = sw;
    }
}

/// Major device number of `dev`.
pub fn major(dev: u64) usize {
    return @intCast((dev >> 8) & 0xff);
}

/// Minor device number of `dev`.
pub fn minor(dev: u64) usize {
    return @intCast(dev & 0xff);
}

/// Pack a major/minor pair into a device number.
pub fn makedev(maj: usize, min: usize) u64 {
    return (@as(u64, maj) << 8) | @as(u64, min);
}
