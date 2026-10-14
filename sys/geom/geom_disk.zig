// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Disks.
//
// The Zig counterpart of FreeBSD's sys/geom/geom_disk.c, without the rest of
// GEOM: a disk driver fills in a struct disk (name, unit, sector size, media
// size and a strategy routine) and calls disk_create(). Filesystems reach
// the disk through the buffer cache (kern/vfs_bio.zig); programs reach it as
// the character device /dev/<name><unit>, as on FreeBSD, where disks have no
// block devices.

const conf: type = @import("../sys/conf.zig");
const errno: type = @import("../sys/errno.zig");
const ioccom: type = @import("../sys/ioccom.zig");
const sysinit: type = @import("../sys/sysinit.zig");
const kmem: type = @import("../kern/subr_kmem.zig");

/// Major number of the disk character devices; the minor is the disk's
/// index in the table below.
pub const DISK_MAJOR: usize = 5;

/// struct disk.
pub const Disk: type = struct {
    /// Driver-chosen name and unit, e.g. "vtbd" and 0 for /dev/vtbd0.
    d_name: []const u8,
    d_unit: u32,
    /// Bytes per sector, and the size of the medium in bytes.
    d_sectorsize: u32,
    d_mediasize: u64,
    /// The medium cannot be written.
    d_readonly: bool = false,
    /// Move `buf.len` bytes (a multiple of the sector size) at byte `offset`;
    /// returns 0 or an errno. Synchronous.
    d_strategy: *const fn (dp: *Disk, write: bool, offset: u64, buf: []u8) i32,
    /// Make completed writes durable (a cache flush); optional.
    d_flush: ?*const fn (dp: *Disk) i32 = null,
    /// Driver-private data.
    d_drv1: ?*anyopaque = null,
};

const MAXDISKS: usize = 8;
var disks: [MAXDISKS]*Disk = undefined;
var ndisks: usize = 0;

/// Make `dp` known to the system.
pub fn disk_create(dp: *Disk) void {
    if (ndisks < MAXDISKS) {
        disks[ndisks] = dp;
        ndisks += 1;
    }
}

/// The disks attached so far.
pub fn list() []*Disk {
    return disks[0..ndisks];
}

/// The device number of disk `i` of list().
pub fn devOf(i: usize) u64 {
    return conf.makedev(DISK_MAJOR, i);
}

/// The disk a device number names, or null.
pub fn fromDev(dev: u64) ?*Disk {
    if (conf.major(dev) != DISK_MAJOR) return null;
    const i: usize = conf.minor(dev);
    return if (i < ndisks) disks[i] else null;
}

/// Write "<name><unit>" into `buf`; returns the slice.
pub fn devName(dp: *const Disk, buf: []u8) []const u8 {
    var n: usize = 0;
    for (dp.d_name) |c| {
        if (n < buf.len) buf[n] = c;
        n += 1;
    }
    var tmp: [10]u8 = undefined;
    var k: usize = 0;
    var u: u32 = dp.d_unit;
    while (true) {
        tmp[k] = @intCast('0' + u % 10);
        k += 1;
        u /= 10;
        if (u == 0) break;
    }
    while (k > 0) {
        k -= 1;
        if (n < buf.len) buf[n] = tmp[k];
        n += 1;
    }
    return buf[0..@min(n, buf.len)];
}

// -- the character device ------------------------------------------------------------

/// DIOCGSECTORSIZE and DIOCGMEDIASIZE (sys/disk.h).
const DIOCGSECTORSIZE: u64 = ioccom.ior('d', 128, u32);
const DIOCGMEDIASIZE: u64 = ioccom.ior('d', 129, i64);

/// A bounce buffer for transfers that are not whole sectors.
var bounce: ?[*]u8 = null;
const BOUNCE_SIZE: usize = 4096;

fn diskOpen(dev: u64, flags: i32) ?*anyopaque {
    _ = flags;
    return @ptrCast(fromDev(dev));
}

fn diskOf(ctx: ?*anyopaque) ?*Disk {
    return @ptrCast(@alignCast(ctx orelse return null));
}

/// Read or write `len` bytes at `offset` through whole-sector transfers.
fn transfer(dp: *Disk, write: bool, offset: u64, ubuf: [*]u8, len: usize) isize {
    if (offset >= dp.d_mediasize) return 0;
    const want: usize = @intCast(@min(@as(u64, len), dp.d_mediasize - offset));
    if (bounce == null) {
        bounce = @ptrCast(kmem.alloc(BOUNCE_SIZE) orelse return -errno.ENOMEM);
    }
    const bb: [*]u8 = bounce.?;
    const ss: u64 = dp.d_sectorsize;
    var done: usize = 0;
    while (done < want) {
        const pos: u64 = offset + done;
        const start: u64 = pos - pos % ss;
        const skip: usize = @intCast(pos - start);
        const chunk: usize = @min(BOUNCE_SIZE - skip, want - done);
        const span: usize = @intCast((skip + chunk + ss - 1) / ss * ss);
        if (!write or skip != 0 or chunk % ss != 0) {
            const e: i32 = dp.d_strategy(dp, false, start, bb[0..span]);
            if (e != 0) return if (done > 0) @intCast(done) else -@as(isize, e);
        }
        if (write) {
            @memcpy(bb[skip .. skip + chunk], ubuf[done .. done + chunk]);
            const e: i32 = dp.d_strategy(dp, true, start, bb[0..span]);
            if (e != 0) return if (done > 0) @intCast(done) else -@as(isize, e);
        } else {
            @memcpy(ubuf[done .. done + chunk], bb[skip .. skip + chunk]);
        }
        done += chunk;
    }
    return @intCast(done);
}

fn diskReadAt(ctx: ?*anyopaque, offset: u64, buf: []u8) isize {
    const dp: *Disk = diskOf(ctx) orelse return -errno.ENXIO;
    return transfer(dp, false, offset, buf.ptr, buf.len);
}

fn diskWriteAt(ctx: ?*anyopaque, offset: u64, buf: []const u8) isize {
    const dp: *Disk = diskOf(ctx) orelse return -errno.ENXIO;
    if (dp.d_readonly) return -errno.EROFS;
    return transfer(dp, true, offset, @constCast(buf.ptr), buf.len);
}

fn diskRead(ctx: ?*anyopaque, buf: []u8) isize {
    return diskReadAt(ctx, 0, buf);
}

fn diskWrite(ctx: ?*anyopaque, buf: []const u8) isize {
    return diskWriteAt(ctx, 0, buf);
}

fn diskIoctl(ctx: ?*anyopaque, cmd: u64, arg: u64) i32 {
    const dp: *Disk = diskOf(ctx) orelse return -errno.ENXIO;
    switch (cmd) {
        DIOCGSECTORSIZE => @as(*align(1) u32, @ptrFromInt(arg)).* = dp.d_sectorsize,
        DIOCGMEDIASIZE => @as(*align(1) i64, @ptrFromInt(arg)).* = @intCast(dp.d_mediasize),
        else => return -errno.ENOTTY,
    }
    return 0;
}

fn diskClose(ctx: ?*anyopaque) i32 {
    _ = ctx;
    return 0;
}

const disk_cdevsw: conf.Cdevsw = .{
    .name = "disk",
    .d_type = conf.D_DISK,
    .open = diskOpen,
    .read = diskRead,
    .write = diskWrite,
    .ioctl = diskIoctl,
    .close = diskClose,
    .read_at = diskReadAt,
    .write_at = diskWriteAt,
};

fn diskAttach(_: ?*const anyopaque) callconv(.c) void {
    conf.registerCdev(DISK_MAJOR, &disk_cdevsw);
}

comptime {
    sysinit.SYSINIT("sysinit_disk", sysinit.SI_SUB_DRIVERS, sysinit.SI_ORDER_SECOND, diskAttach, null);
}
