// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Device switch tables.
//
// This is the Zig counterpart of NetBSD's sys/sys/conf.h, reduced to the
// character device switch: a table indexed by device major number, holding a
// vector of routines that a device driver provides. open(2) on a character
// device node dispatches through here.

/// Number of major device numbers.
pub const NCDEV: usize = 16;

/// Device classes (sys/conf.h D_TYPEMASK values).
pub const D_TAPE: u32 = 0x0001;
pub const D_DISK: u32 = 0x0002;
pub const D_TTY: u32 = 0x0004;
pub const D_MEM: u32 = 0x0008;

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
    /// Handle a device-specific control request.
    ioctl: *const fn (ctx: ?*anyopaque, cmd: u64, arg: u64) i32,
    /// Map device memory: return the physical address for `offset`, or null.
    mmap: ?*const fn (ctx: ?*anyopaque, offset: u64, prot: u32) ?u64 = null,
    /// Called when the last reference to the open file is dropped.
    close: *const fn (ctx: ?*anyopaque) i32,
    /// Readiness for poll(2)/select(2), as FreeBSD's d_poll: the POLL* bits
    /// that hold now. Devices without it are always ready.
    poll: ?*const fn (ctx: ?*anyopaque) u16 = null,
    /// The device class FIODTYPE reports (D_DISK, D_TTY, D_MEM; 0 for
    /// others), from FreeBSD's d_flags.
    d_type: u32 = 0,
    /// Positioned transfers, for devices with an address space (disks):
    /// when present they are used instead of read/write, at the open file's
    /// offset, which then advances.
    read_at: ?*const fn (ctx: ?*anyopaque, offset: u64, buf: []u8) isize = null,
    write_at: ?*const fn (ctx: ?*anyopaque, offset: u64, buf: []const u8) isize = null,
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
